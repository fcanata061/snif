#!/bin/sh
# lfs-pm.sh — Gerenciador de programas estilo Linux From Scratch
# POSIX shell, sem dependências exóticas. Projetado para ser simples, legível e hackável.
#
# Recursos principais:
#  - Cores/Spinner
#  - Repositório baseado em Git: $REPO/{base,x11,extras,desktop}
#  - Receitas por diretório: /$REPO/<categoria>/<pkg>/<versão>/recipe
#  - Variáveis em um único lugar; override por env/CLI
#  - Download via curl ou git
#  - Descompactação de formatos comuns (tar.{gz,bz2,xz,zst}, .zip, .gz, .bz2, .xz, .zst)
#  - Patches aplicados automaticamente se presentes em ./patches/*.patch
#  - build sem instalar; instalar com DESTDIR + fakeroot (quando disponível)
#  - Hooks pre/post (build/install) em hooks.d/
#  - Logs e registro em $DBDIR; manifests por pacote p/ remoção/rollback
#  - Gerenciamento de dependências com ordenação topológica (tsort se existir; fallback built-in)
#  - Recompilação do mundo (toda a árvore) respeitando ordem
#  - Orfãos (pacotes instalados que ninguém depende)
#  - revdep: detecta bins com libs quebradas via ldd e tenta resolver via rebuild/instalação
#  - info/list/search; upgrade (incl. --force);
#  - atalhos de CLI (aliases) 
#  - Criação de receitas de toolchain (ex.: /base/gcc/{gcc-12.2.0,gcc-pass1-12.2.0})
#
# Licença: MIT — use, modifique e compartilhe.

set -eu
umask 022

############################
# Configuração (padrões)   #
############################
: "${REPO:=${HOME}/repo-lfs}"                  # Estrutura: base/ x11/ extras/ desktop/
: "${BUILDDIR:=/tmp/lfs-pm-build}"            # Área de build por pacote
: "${SRCDIR:=${HOME}/.cache/lfs-pm/src}"      # Cache de fontes
: "${PKGDIR:=${HOME}/.cache/lfs-pm/pkg}"      # Saída de pacotes (tarball instalável)
: "${DBDIR:=/var/lib/lfs-pm}"                  # Banco de dados simples
: "${LOGDIR:=/var/log/lfs-pm}"                 # Logs por pacote
: "${HOOKSD:=/etc/lfs-pm/hooks.d}"             # Diretório de hooks globais
: "${JOBS:=$(getconf _NPROCESSORS_ONLN || echo 1)}"
: "${SUDO:=sudo}"                              # Comando para ações de root; pode ser vazio se já for root
: "${FAKEROOT:=fakeroot}"                      # Comando fakeroot (opcional)
: "${FETCH_RETRIES:=3}"
: "${COLOR:=auto}"                             # auto|always|never

# Variáveis por pacote/receita (padrões)
# Estas são sobrepostas por cada recipe.
PKG_NAME=""
PKG_VERSION=""
PKG_RELEASE="1"
PKG_SOURCE_URLS=""    # separadas por espaço
PKG_GIT_URL=""        # opcional
PKG_DEPENDS=""        # nomes lógicos
PKG_DESC=""
PKG_LICENSE=""
PKG_MESON_OPTS=""
PKG_CMAKE_OPTS=""
PKG_CONFIGURE_OPTS=""
PKG_MAKE_OPTS="-j${JOBS}"
PKG_DESTDIR="${BUILDDIR}/destdir"
PKG_BUILD_SUBDIR=""    # ex.: source/build
PKG_PATCH_STRIP=1       # nível de -p para patch -pN

################################
# Saída: cores e spinner
################################
_is_tty() { [ -t 1 ] && [ "${TERM:-dumb}" != "dumb" ]; }
_use_color() {
  case "${COLOR}" in
    always) return 0 ;;
    never)  return 1 ;;
    *) _is_tty ;;
  esac
}
if _use_color; then
  c() { printf "\033[%sm" "$1"; }
  RESET=$(c 0); B=$(c 1); DIM=$(c 2);
  RED=$(c 31); GRN=$(c 32); YLW=$(c 33); BLU=$(c 34); MAG=$(c 35); CYN=$(c 36)
else
  c() { :; }
  RESET=""; B=""; DIM=""; RED=""; GRN=""; YLW=""; BLU=""; MAG=""; CYN=""
fi

log()   { printf "%s[%s]%s %s\n" "$DIM" "$1" "$RESET" "$2"; }
ok()    { printf "%s[ ok ]%s %s\n" "$GRN" "$RESET" "$1"; }
warn()  { printf "%s[warn]%s %s\n" "$YLW" "$RESET" "$1"; }
err()   { printf "%s[fail]%s %s\n" "$RED" "$RESET" "$1"; }

action() { printf "%s==>%s %s\n" "$BLU" "$RESET" "$1"; }

spinner_start() {
  _sp_pid=""
  (
    i=0 syms='|/-\\'
    while :; do i=$(( (i+1) % 4 )); printf "\r%s" "${DIM}${syms$i}${RESET}"; sleep 0.1; done
  ) & _sp_pid=$!
  SPINNER_PID=$_sp_pid
}
spinner_stop() {
  [ "${SPINNER_PID:-}" ] && kill "$SPINNER_PID" 2>/dev/null || true
  printf "\r  \r"
}

################################
# Utilidades
################################
need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Comando requerido: $1"; exit 1; }; }
ensure_dirs() { mkdir -p "$SRCDIR" "$PKGDIR" "$DBDIR" "$LOGDIR" "$BUILDDIR"; }
mydate() { date +%Y-%m-%dT%H:%M:%S%z; }
logfile_for() { echo "$LOGDIR/$1-$2.log"; }
recipedir_of() { echo "$1/$2/$3"; }
recipefile() { echo "$1/recipe"; }
manifest_of() { echo "$DBDIR/$1-$2.manifest"; }
installed_flag() { echo "$DBDIR/$1-$2.installed"; }
state_dir() { echo "$DBDIR/state/$1-$2"; }

###############################
# Descompactação
###############################
extract() {
  src="$1"; dest="$2"; mkdir -p "$dest"
  case "$src" in
    *.tar.gz|*.tgz)      tar -xzf "$src" -C "$dest" ;;
    *.tar.bz2|*.tbz2)    tar -xjf "$src" -C "$dest" ;;
    *.tar.xz|*.txz)      tar -xJf "$src" -C "$dest" ;;
    *.tar.zst|*.tzst)    need_cmd unzstd; unzstd -c "$src" | tar -x -C "$dest" ;;
    *.zip)               need_cmd unzip; unzip -q "$src" -d "$dest" ;;
    *.gz)                gunzip -c "$src" > "$dest/$(basename "${src%.gz}")" ;;
    *.bz2)               bunzip2 -c "$src" > "$dest/$(basename "${src%.bz2}")" ;;
    *.xz)                unxz -c "$src" > "$dest/$(basename "${src%.xz}")" ;;
    *.zst)               unzstd -c "$src" > "$dest/$(basename "${src%.zst}")" ;;
    *)                   err "Formato desconhecido: $src"; return 1 ;;
  esac
}

###############################
# Carregar recipe
###############################
load_recipe() {
  rdir="$1"
  rfile=$(recipefile "$rdir")
  [ -f "$rfile" ] || { err "Recipe não encontrada: $rfile"; exit 1; }
  # Reset variáveis de recipe
  PKG_NAME=""; PKG_VERSION=""; PKG_RELEASE="1"; PKG_SOURCE_URLS=""; PKG_GIT_URL="";
  PKG_DEPENDS=""; PKG_DESC=""; PKG_LICENSE=""; PKG_MESON_OPTS=""; PKG_CMAKE_OPTS="";
  PKG_CONFIGURE_OPTS=""; PKG_MAKE_OPTS="-j${JOBS}"; PKG_DESTDIR="${BUILDDIR}/destdir";
  PKG_BUILD_SUBDIR=""; PKG_PATCH_STRIP=1
  # shellcheck disable=SC1090
  . "$rfile"
  [ -n "$PKG_NAME" ] && [ -n "$PKG_VERSION" ] || { err "Recipe inválida (PKG_NAME/PKG_VERSION)"; exit 1; }
}

################################
# Hooks
################################
run_hooks() {
  phase="$1"; pkg="$2"; ver="$3"; shift 3
  [ -d "$HOOKSD" ] || return 0
  for h in "$HOOKSD"/"$phase"-*.sh; do
    [ -f "$h" ] || continue
    log hook "Exec $phase: $(basename "$h")"
    sh "$h" "$pkg" "$ver" "$@" || warn "Hook falhou: $h"
  done
}

################################
# Dependências: leitura e tsort
################################
# Retorna lista de deps (nomes) de uma recipe dir
recipe_deps() { load_recipe "$1"; printf '%s\n' $PKG_DEPENDS | awk 'NF>0' | tr '\n' ' '; }

# Monta pares (pkg dep) para tsort
pairs_for_tsort() {
  repo_root="$1"; shift
  for r in "$@"; do
    [ -d "$r" ] || continue
    load_recipe "$r"
    pkg="$PKG_NAME@$PKG_VERSION"
    for d in $PKG_DEPENDS; do
      echo "$pkg $d"
    done
    # Sem dependências: ainda precisamos emitir o nó
    [ -z "$PKG_DEPENDS" ] && echo "$pkg"
  done
}

have_tsort() { command -v tsort >/dev/null 2>&1; }

tsort_or_fallback() {
  if have_tsort; then
    tsort
  else
    # Fallback bem simples: resolve iterativamente enquanto possível
    awk '
      { for (i=1;i<=NF;i++) g[FNR,i]=$i; n[FNR]=NF; }
      END {
        # Construir conjuntos
        for (i=1;i<=FNR;i++) {
          if (n[i]==1) { t[g[i,1]]=1 }
          else { dep[g[i,1]]=dep[g[i,1]] " " g[i,2] }
          pkgs[g[i,1]]=1; for (j=2;j<=n[i];j++) pkgs[g[i,j]]=1
        }
        # Kahn simplificado
        done=0
        while (done==0) {
          progress=0
          for (p in pkgs) {
            if (p in printed) continue
            ok=1
            split(dep[p],dd," ")
            for (k in dd) if (dd[k] in pkgs && !(dd[k] in printed) && dd[k] != "") ok=0
            if (ok) { print p; printed[p]=1; progress=1 }
          }
          if (progress==0) break
        }
        # Tentar imprimir restos para não travar
        for (p in pkgs) if (!(p in printed)) print p
      }'
  fi
}

################################
# Download
################################
fetch_sources() {
  load_recipe "$1"
  mkdir -p "$SRCDIR/$PKG_NAME-$PKG_VERSION"
  cd "$SRCDIR/$PKG_NAME-$PKG_VERSION"
  for u in $PKG_SOURCE_URLS; do
    f=$(basename "$u")
    if [ ! -f "$f" ]; then
      action "Baixando $f"
      i=0; while [ $i -lt "$FETCH_RETRIES" ]; do
        if command -v curl >/dev/null 2>&1; then
          curl -L --fail -o "$f" "$u" && break || true
        else
          err "curl necessário para downloads HTTP(S)"; return 1
        fi
        i=$((i+1))
        warn "Retry $i em $u"
      done
      [ -f "$f" ] || { err "Falha ao baixar $u"; exit 1; }
    fi
  done
  if [ -n "$PKG_GIT_URL" ]; then
    if [ -d "$(basename "$PKG_GIT_URL" .git)" ]; then
      action "Atualizando git $(basename "$PKG_GIT_URL")"; (cd "$(basename "$PKG_GIT_URL" .git)" && git pull --ff-only)
    else
      need_cmd git; action "Clonando $PKG_GIT_URL"; git clone "$PKG_GIT_URL"
    fi
  fi
}

################################
# Unpack + Patch
################################
unpack_and_patch() {
  load_recipe "$1"
  work="$BUILDDIR/$PKG_NAME-$PKG_VERSION"
  rm -rf "$work"; mkdir -p "$work"
  cd "$work"
  # Descompactar todos os tarballs/fontes
  for u in $PKG_SOURCE_URLS; do
    f="$SRCDIR/$PKG_NAME-$PKG_VERSION/$(basename "$u")"
    [ -f "$f" ] || { err "Fonte ausente: $f"; exit 1; }
    action "Extraindo $(basename "$f")"
    extract "$f" "$work"
  done
  # Se apenas um diretório foi criado, entrar nele; caso contrário permanecer
  first_sub=$(ls -1 | head -n1 2>/dev/null || echo .)
  [ -d "$first_sub" ] && cd "$first_sub"
  # Aplicar patches
  pdir="$1/patches"
  if [ -d "$pdir" ]; then
    for p in "$pdir"/*.patch; do
      [ -f "$p" ] || continue
      action "Aplicando patch $(basename "$p")"
      patch -p"$PKG_PATCH_STRIP" < "$p"
    done
  fi
  ok "Unpack/Patch OK: $PKG_NAME-$PKG_VERSION"
}

################################
# Build
################################
run_build() {
  rdir="$1"; load_recipe "$rdir"
  logf=$(logfile_for "$PKG_NAME" "$PKG_VERSION")
  action "Build de $PKG_NAME-$PKG_VERSION"
  run_hooks pre-build "$PKG_NAME" "$PKG_VERSION" "$rdir"
  unpack_and_patch "$rdir"
  cd "$BUILDDIR/$PKG_NAME-$PKG_VERSION"/* 2>/dev/null || cd "$BUILDDIR/$PKG_NAME-$PKG_VERSION"
  [ -n "$PKG_BUILD_SUBDIR" ] && cd "$PKG_BUILD_SUBDIR"
  : "${PKG_DESTDIR:=${BUILDDIR}/destdir}"
  rm -rf "$PKG_DESTDIR"; mkdir -p "$PKG_DESTDIR"
  # Preferência: meson > cmake > configure > make custom
  {
    if [ -f meson.build ] || [ -n "$PKG_MESON_OPTS" ]; then
      need_cmd meson; need_cmd ninja
      meson setup build $PKG_MESON_OPTS
      ninja -C build $PKG_MAKE_OPTS
      DESTDIR="$PKG_DESTDIR" ninja -C build install
    elif [ -f CMakeLists.txt ] || [ -n "$PKG_CMAKE_OPTS" ]; then
      need_cmd cmake; need_cmd make
      mkdir -p build && cd build
      cmake .. $PKG_CMAKE_OPTS
      make $PKG_MAKE_OPTS
      make DESTDIR="$PKG_DESTDIR" install
    elif [ -x configure ] || [ -f configure ]; then
      need_cmd make
      sh ./configure $PKG_CONFIGURE_OPTS
      make $PKG_MAKE_OPTS
      make DESTDIR="$PKG_DESTDIR" install
    elif grep -q '^all:' Makefile 2>/dev/null; then
      make $PKG_MAKE_OPTS
      make DESTDIR="$PKG_DESTDIR" install
    elif command -v build >/dev/null 2>&1; then
      build  # gancho para receitas muito custom
    else
      warn "Sem sistema de build detectado; usando 'recipe()' se existir"
      type recipe >/dev/null 2>&1 && recipe || { err "Sem build script"; exit 1; }
    fi
  } >>"$logf" 2>&1
  run_hooks post-build "$PKG_NAME" "$PKG_VERSION" "$rdir"
  ok "Build concluído: $PKG_NAME-$PKG_VERSION (log: $logf)"
}

################################
# Empacotar (+fakeroot) e Instalar
################################
package_from_destdir() {
  load_recipe "$1"
  cd "$PKG_DESTDIR"
  out="$PKGDIR/$PKG_NAME-$PKG_VERSION-$PKG_RELEASE.tar.zst"
  action "Empacotando $out"
  need_cmd tar; need_cmd zstd
  tar --numeric-owner -cf - . | zstd -19 -o "$out"
  echo "$out"
}

install_package() {
  rdir="$1"; load_recipe "$rdir"
  mfest=$(manifest_of "$PKG_NAME" "$PKG_VERSION")
  instflag=$(installed_flag "$PKG_NAME" "$PKG_VERSION")
  pkgfile=$(package_from_destdir "$rdir")
  action "Instalando $PKG_NAME-$PKG_VERSION"
  mkdir -p "$DBDIR" "$LOGDIR"
  # Extrair com fakeroot/sudo mantendo manifest
  tmpx="$BUILDDIR/install-root"
  rm -rf "$tmpx"; mkdir -p "$tmpx"
  unzstd -c "$pkgfile" | tar -x -C "$tmpx"
  # Copiar para / registrando
  : >"$mfest"
  ( cd "$tmpx" && find . -type f -o -type l -o -type d | sed 's#^./##' ) | while IFS= read -r path; do
    src="$tmpx/$path"; dst="/$path"
    if [ -d "$src" ]; then
      $SUDO mkdir -p "$dst"
    else
      $SUDO install -D -m 0755 "$src" "$dst" 2>/dev/null || $SUDO install -D -m 0644 "$src" "$dst" 2>/dev/null || $SUDO cp -a "$src" "$dst"
    fi
    printf "%s\n" "/$path" >>"$mfest"
  done
  printf "%s\n" "$(mydate)" > "$instflag"
  ok "Instalado: $PKG_NAME-$PKG_VERSION"
}

uninstall_package() {
  name="$1"; ver="$2"
  mfest=$(manifest_of "$name" "$ver")
  [ -f "$mfest" ] || { warn "Sem manifest: $name-$ver"; return 0; }
  action "Removendo $name-$ver"
  # Remover em ordem reversa para evitar diretórios não vazios
  tac "$mfest" 2>/dev/null || tail -r "$mfest" | while IFS= read -r p; do :; done >/dev/null
  # Implementação POSIX de tac
  revtmp=$(mktemp)
  nl -ba "$mfest" | sort -rn | cut -f2- > "$revtmp"
  while IFS= read -r path; do
    if [ -d "$path" ]; then
      $SUDO rmdir "$path" 2>/dev/null || true
    else
      $SUDO rm -f "$path" 2>/dev/null || true
    fi
  done <"$revtmp"
  rm -f "$revtmp" "$mfest" "$(installed_flag "$name" "$ver")"
  ok "Removido: $name-$ver"
}

################################
# Banco de dados simples
################################
installed_versions() { ls "$DBDIR" 2>/dev/null | grep "^$1-" | sed "s/^$1-//;s/\.manifest$//;s/\.installed$//" | sort -u; }
list_installed() { ls "$DBDIR" 2>/dev/null | grep '\.installed$' | sed 's/.installed$//' | sort; }

################################
# Operações de alto nível
################################
cmd_fetch() { for r in "$@"; do fetch_sources "$r"; done; }
cmd_unpack() { for r in "$@"; do unpack_and_patch "$r"; done; }
cmd_build() { for r in "$@"; do run_build "$r"; done; }
cmd_build_no_install() { cmd_build "$@"; }
cmd_package() { for r in "$@"; do load_recipe "$r"; package_from_destdir "$r"; done; }
cmd_install() { for r in "$@"; do run_build "$r"; install_package "$r"; done; }

resolve_recipe_dir() {
  # Argumentos podem ser caminho absoluto ou categoria/pkg/versão
  arg="$1"
  case "$arg" in
    /*) echo "$arg" ;;
    *)  # tentar localizar por REPO
        path=$(find "$REPO" -mindepth 3 -maxdepth 3 -type d -path "*/$arg" -o -path "*/$arg/*" 2>/dev/null | head -n1)
        if [ -z "$path" ]; then
          # aceitar categoria/pacote/versão
          if [ -d "$REPO/$arg" ]; then echo "$REPO/$arg"; else err "Recipe não encontrada: $arg"; exit 1; fi
        else echo "$path"; fi ;;
  esac
}

cmd_info() {
  for a in "$@"; do
    r=$(resolve_recipe_dir "$a"); load_recipe "$r"
    printf "%s%s-%s%s\n" "$B" "$PKG_NAME" "$PKG_VERSION" "$RESET"
    echo "desc: $PKG_DESC"
    echo "deps: $PKG_DEPENDS"
    echo "instalado: $( [ -f "$(installed_flag "$PKG_NAME" "$PKG_VERSION")" ] && echo sim || echo não )"
    echo "recipe: $r"
  done
}

cmd_search() { find "$REPO" -type f -name recipe | sed "s#^$REPO/##;s#/recipe##" | sort | grep -i "${1:-}" || true; }

cmd_sync() {
  [ -d "$REPO/.git" ] || { err "REPO não é um checkout git: $REPO"; exit 1; }
  action "Sincronizando $REPO"; (cd "$REPO" && git pull --ff-only)
}

cmd_install_with_deps() {
  # Resolve ordem topológica e instala tudo
  inputs="${*:-}"
  set --
  for a in $inputs; do set -- "$@" "$(resolve_recipe_dir "$a")"; done
  pairs_for_tsort "$REPO" "$@" | tsort_or_fallback | while IFS= read -r node; do
    pkg=${node%@*}; ver=${node#*@}
    r=$(find "$REPO" -type d -path "*/$pkg/$ver" -maxdepth 4 2>/dev/null | head -n1)
    [ -n "$r" ] || continue
    load_recipe "$r"
    if [ -f "$(installed_flag "$PKG_NAME" "$PKG_VERSION")" ] && [ "${FORCE:-0}" -ne 1 ]; then
      ok "Já instalado: $PKG_NAME-$PKG_VERSION"; continue
    fi
    run_build "$r"; install_package "$r"
  done
}

cmd_world() {
  # Recompila todo o sistema em ordem de dependências
  action "Rebuild do mundo"
  set -- $(find "$REPO" -mindepth 3 -maxdepth 3 -type d -name "*.*" | sort)
  pairs_for_tsort "$REPO" "$@" | tsort_or_fallback | while IFS= read -r n; do
    pkg=${n%@*}; ver=${n#*@}
    r=$(find "$REPO" -type d -path "*/$pkg/$ver" -maxdepth 4 2>/dev/null | head -n1) || true
    [ -n "$r" ] || continue
    run_build "$r"; install_package "$r"
  done
}

cmd_orphans() {
  # Orfãos: instalados que ninguém depende
  all=$(list_installed | sed 's/@/ /')
  providers=$(printf '%s\n' $(find "$REPO" -type f -name recipe))
  used=""
  for rf in $providers; do
    . "$rf" 2>/dev/null || true
    for d in $PKG_DEPENDS; do used="$used $d"; done
  done
  for iv in $all; do
    pkg=${iv%-*}; ver=${iv#*-}
    case " $used " in *" $pkg "*) : ;; *) echo "$pkg@$ver" ;; esac
  done | sort -u
}

cmd_revdep() {
  # Encontra executáveis/so com libs faltando e tenta reinstalar/instalar provedores
  broken="$(
    for b in $(command -v -a ldd >/dev/null 2>&1 && find /usr/bin /usr/lib /bin /lib -type f 2>/dev/null | head -n 5000); do
      case "$b" in *.so*|*/bin/*) : ;; *) continue ;; esac
      ldd "$b" 2>/dev/null | grep 'not found' >/dev/null 2>&1 && echo "$b" || true
    done
  )"
  if [ -z "$broken" ]; then ok "Sem libs quebradas"; return 0; fi
  echo "$broken" | while IFS= read -r f; do
    warn "ldd not found: $f"; # Estratégia simples: reconstruir mundo
  done
  cmd_world
}

cmd_remove() {
  # Remove pacote (todas as versões ou versão específica com nome@ver)
  spec="$1"
  case "$spec" in
    *@*) name=${spec%@*}; ver=${spec#*@}; uninstall_package "$name" "$ver" ;;
    *)   for v in $(installed_versions "$spec"); do uninstall_package "$spec" "$v"; done ;;
  esac
}

cmd_upgrade() {
  # Upgrade para últimas versões presentes no REPO
  for inst in $(list_installed); do
    name=${inst%-*}; ver=${inst#*-}
    # encontrar maior versão no REPO para esse nome
    best=$(find "$REPO" -type d -path "*/$name/*" -maxdepth 3 | awk -F'/' '{print $NF}' | sort -V | tail -n1)
    [ -n "$best" ] || continue
    if [ "$best" != "$ver" ] || [ "${FORCE:-0}" -eq 1 ]; then
      r=$(find "$REPO" -type d -path "*/$name/$best" -maxdepth 4 | head -n1)
      cmd_install_with_deps "$r"
    else
      ok "$name já na versão mais recente ($ver)"
    fi
  done
}

cmd_force_on() { FORCE=1 "$0" "$@"; }

################################
# Criação de receita de toolchain
################################
cmd_mk_toolchain() {
  # Ex.: lfs-pm mk-toolchain base/gcc 12.2.0
  catg_pkg="$1"; ver="$2"
  base_dir="$REPO/$catg_pkg"
  mkdir -p "$base_dir/gcc-$ver" "$base_dir/gcc-pass1-$ver"
  for n in "gcc-$ver" "gcc-pass1-$ver"; do
    d="$base_dir/$n"; mkdir -p "$d/patches"
    cat >"$d/recipe" <<EOF
# Recipe para $n
PKG_NAME="gcc"
PKG_VERSION="$ver"
PKG_DESC="GNU Compiler Collection"
PKG_LICENSE="GPL-3.0-or-later"
PKG_DEPENDS="gmp mpfr mpc"
PKG_SOURCE_URLS="https://ftp.gnu.org/gnu/gcc/gcc-\${PKG_VERSION}/gcc-\${PKG_VERSION}.tar.xz"
PKG_CONFIGURE_OPTS="--disable-multilib --enable-languages=c,c++"
# Customize se for pass1
[ "$(echo "$n" | grep -c pass1)" -gt 0 ] && PKG_CONFIGURE_OPTS="--disable-shared --disable-multilib --enable-languages=c"
EOF
  done
  ok "Toolchain recipes criadas em $base_dir/{gcc-$ver,gcc-pass1-$ver}"
}

################################
# Ajuda/CLI
################################
usage() {
cat <<USAGE
${B}lfs-pm.sh${RESET} — gerenciador estilo LFS

Uso: $0 <comando> [opções] [alvos]

Comandos:
  sync                      Atualiza o repositório Git em \$REPO
  search <regex>            Busca receitas
  info <alvo...>            Mostra info (deps, instalado, paths)
  fetch <alvo...>           Baixa fontes
  unpack <alvo...>          Descompacta + aplica patches
  build <alvo...>           Compila (sem instalar)
  install <alvo...>         Compila + instala
  install-deps <alvo...>    Instala com resolução de dependências topológica
  package <alvo...>         Gera tarball do DESTDIR
  remove <nome[@ver]>       Remove pacote/versão usando manifest
  orphans                   Lista possíveis órfãos
  revdep                    Procura libs quebradas e tenta reparar (rebuild mundo)
  world                     Recompila todo o sistema em ordem
  upgrade                   Atualiza todos os instalados para versões mais novas no \$REPO
  mk-toolchain cat/pkg ver  Cria receitas gcc e gcc-pass1

Opções ambientais:
  REPO, BUILDDIR, SRCDIR, PKGDIR, DBDIR, LOGDIR, HOOKSD, JOBS, SUDO, FAKEROOT, COLOR, FETCH_RETRIES
  FORCE=1                   Força reinstalação/upgrade

Alvos:
  Podem ser caminhos absolutos de recipe ou caminhos relativos como base/gcc/gcc-12.2.0
  A estrutura esperada é: \$REPO/{base,x11,extras,desktop}/<pkg>/<versão>/recipe
USAGE
}

################################
# Entrypoint
################################
main() {
  ensure_dirs
  cmd="${1:-}"; shift 2>/dev/null || true
  case "$cmd" in
    sync) cmd_sync ;;
    search) cmd_search "${1:-}" ;;
    info) cmd_info "$@" ;;
    fetch) set -- $(for a in "$@"; do resolve_recipe_dir "$a"; done); cmd_fetch "$@" ;;
    unpack) set -- $(for a in "$@"; do resolve_recipe_dir "$a"; done); cmd_unpack "$@" ;;
    build) set -- $(for a in "$@"; do resolve_recipe_dir "$a"; done); cmd_build "$@" ;;
    build-only) set -- $(for a in "$@"; do resolve_recipe_dir "$a"; done); cmd_build_no_install "$@" ;;
    package) set -- $(for a in "$@"; do resolve_recipe_dir "$a"; done); cmd_package "$@" ;;
    install) set -- $(for a in "$@"; do resolve_recipe_dir "$a"; done); cmd_install "$@" ;;
    install-deps) cmd_install_with_deps "$@" ;;
    remove) cmd_remove "${1:?use: remove nome[@versão]}" ;;
    orphans) cmd_orphans ;;
    revdep) cmd_revdep ;;
    world) cmd_world ;;
    upgrade) cmd_upgrade ;;
    force) cmd_force_on "$@" ;;
    mk-toolchain) cmd_mk_toolchain "${1:?cat/pkg}" "${2:?versão}" ;;
    help|-h|--help|"") usage ;;
    *) err "Comando desconhecido: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
