#!/bin/sh
# bookworm / trixie の 2 系統について、イメージと bindist を作る。push はしない。
#
#   ./build.sh                                   # 両方
#   CODENAMES=trixie ./build.sh                  # trixie だけ
#   IMAGE=ghcr.io/khibino/ghc-pie ./build.sh     # ghcr.io 用の名前で作る
#   DATE=20261024 ./build.sh                     # 日付を固定する（既定は今日）
#   DOCKER_BUILD_ARGS="--build-arg HADRIAN_DOCS=no-sphinx" ./build.sh
#
# できるもの（DATE=20261024 の例）
#   イメージ : ${IMAGE}:9.6.7-bookworm-20261024 と ${IMAGE}:9.6.7-bookworm（trixie も同様）
#   bindist  : dist/20261024/ghc-9.6.7-x86_64-deb12-linux.tar.xz（bookworm）
#              dist/20261024/ghc-9.6.7-x86_64-deb13-linux.tar.xz（trixie）
#              dist/20261024/SHA256SUMS
# 最後に docker push のコマンド例を表示する。
set -eu
cd "$(dirname "$0")"

GHC_VERSION=${GHC_VERSION:-9.6.7}
IMAGE=${IMAGE:-ghc-pie}
CODENAMES=${CODENAMES:-"bookworm trixie"}
DATE=${DATE:-$(date +%Y%m%d)}
BUILD_DATE=${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
DOCKER_BUILD_ARGS=${DOCKER_BUILD_ARGS:-}

# GHC 公式 bindist の命名（deb12 = bookworm, deb13 = trixie）に合わせる
debian_number() {
    case "$1" in
        bookworm) echo 12 ;;
        trixie)   echo 13 ;;
        forky)    echo 14 ;;
        *) echo "unknown Debian codename: $1" >&2; exit 1 ;;
    esac
}

outdir="dist/${DATE}"
mkdir -p "${outdir}"
tags=""

for codename in $CODENAMES; do
    deb="deb$(debian_number "$codename")"
    tag_dated="${IMAGE}:${GHC_VERSION}-${codename}-${DATE}"
    tag_plain="${IMAGE}:${GHC_VERSION}-${codename}"

    echo "=== ${tag_dated}"
    # shellcheck disable=SC2086
    docker build $DOCKER_BUILD_ARGS \
        --build-arg "DEBIAN_CODENAME=${codename}" \
        --build-arg "GHC_VERSION=${GHC_VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        -t "${tag_dated}" -t "${tag_plain}" .

    # 同じキャッシュから bindist だけを取り出し、系統が分かる名前に改める
    tmp=$(mktemp -d "${outdir}/.export.XXXXXX")
    # shellcheck disable=SC2086
    docker build $DOCKER_BUILD_ARGS \
        --build-arg "DEBIAN_CODENAME=${codename}" \
        --build-arg "GHC_VERSION=${GHC_VERSION}" \
        --target bindist --output "type=local,dest=${tmp}" .
    mv "${tmp}/ghc-${GHC_VERSION}-x86_64-unknown-linux.tar.xz" \
       "${outdir}/ghc-${GHC_VERSION}-x86_64-${deb}-linux.tar.xz"
    rm -rf "${tmp}"

    tags="${tags} ${tag_dated} ${tag_plain}"
done

(cd "${outdir}" && sha256sum ghc-*.tar.xz > SHA256SUMS)

echo
echo "=== bindist: ${outdir}"
ls -l "${outdir}"
cat "${outdir}/SHA256SUMS"
echo
echo "=== images"
for t in $tags; do echo "  $t"; done
echo
echo "push するときは（自動では push しない）:"
for t in $tags; do echo "  docker push $t"; done
