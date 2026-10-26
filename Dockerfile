# syntax=docker/dockerfile:1
#
# すべてのオブジェクトコード（.a の中身を含む）を -fPIC でビルドした GHC。
# `ghc -fPIC -pie -optl-static-pie` で static-pie な実行ファイルを作れる。
#
#   docker build --build-arg DEBIAN_CODENAME=bookworm -t ghc-pie:9.6.7-bookworm .
#   docker build --build-arg DEBIAN_CODENAME=trixie   -t ghc-pie:9.6.7-trixie   .
#
# bindist（tar.xz）だけを取り出す:
#   docker build --target bindist --output type=local,dest=dist/bookworm .
#
# 日付付きタグや bindist の改名まで含めた手順は build.sh にある。

ARG DEBIAN_CODENAME=bookworm

###############################################################################
# 1. builder: ghcup で入れた GHC を boot compiler にして GHC をソースからビルド
###############################################################################
FROM debian:${DEBIAN_CODENAME}-slim AS builder

ARG GHC_VERSION=9.6.7
ARG GHC_SRC_SHA256=d053bf6ce1d588a75cfe8c9316269486e9d8fb89dcdf6fd92836fa2e3df61305
ARG GHCUP_VERSION=0.2.6.2
ARG GHCUP_SHA256=9ed5da5449b48043a0d17e767c05d2ef585e25a639bb934329496c6d2fad9cf8
# boot compiler。9.6.x は 9.4 以降の GHC でビルドできる。ここでは同じ版を使う。
ARG BOOT_GHC_VERSION=9.6.7
ARG CABAL_VERSION=3.12.1.0
# hadrian の flavour と docs。haddock も付けたいときは HADRIAN_DOCS=no-sphinx
ARG HADRIAN_FLAVOUR=release
ARG HADRIAN_DOCS=none
# hadrian の並列数（-j）。空ならコンテナから見える CPU 数（nproc）。
ARG BUILD_JOBS=

# XZ_OPT=-T0 : bindist を固める xz を全コアで走らせる（既定は 1 スレッドで 10 分以上かかる）。
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    XZ_OPT=-T0

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential autoconf automake libtool m4 pkg-config \
        ca-certificates curl xz-utils git python3 \
        libgmp-dev libncurses-dev libffi-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# ghcup 本体（単体バイナリ）。SHA256 を確認してから置く。
RUN curl -fsSL -o /usr/local/bin/ghcup \
        "https://downloads.haskell.org/~ghcup/${GHCUP_VERSION}/x86_64-linux-ghcup-${GHCUP_VERSION}" \
    && echo "${GHCUP_SHA256}  /usr/local/bin/ghcup" | sha256sum -c - \
    && chmod 0755 /usr/local/bin/ghcup

ENV PATH=/root/.ghcup/bin:${PATH}

# boot compiler と、hadrian をビルドするための cabal
RUN ghcup install ghc "${BOOT_GHC_VERSION}" --set \
    && ghcup install cabal "${CABAL_VERSION}" --set \
    && ghcup gc --cache \
    && cabal update

# GHC のソース。SHA256 は https://downloads.haskell.org/~ghc/9.6.7/SHA256SUMS の値。
WORKDIR /build
RUN curl -fsSLO "https://downloads.haskell.org/~ghc/${GHC_VERSION}/ghc-${GHC_VERSION}-src.tar.xz" \
    && echo "${GHC_SRC_SHA256}  ghc-${GHC_VERSION}-src.tar.xz" | sha256sum -c - \
    && tar -xJf "ghc-${GHC_VERSION}-src.tar.xz" \
    && rm "ghc-${GHC_VERSION}-src.tar.xz"

WORKDIR /build/ghc-${GHC_VERSION}

# --with-intree-gmp : gmp を in-tree で（--with-pic=yes で）ビルドし ghc-bignum に組み込む。
#                     利用側の最終リンクで Debian の libgmp.a に依存しなくなる。
# --disable-numa    : rts が libnuma にリンクしないようにする（static-pie の依存を減らす）。
RUN ./configure --with-intree-gmp --disable-numa

# 肝心の部分。stage1 の GHC が作るライブラリ・rts のオブジェクトをすべて -fPIC にする。
#   ghc.hs.opts : Haskell モジュールのコンパイル
#   ghc.c.opts  : GHC 経由でコンパイルする C（rts、各ライブラリの cbits）。
#                 これが無いと GHC が C コンパイラに -fno-PIC を付ける。
#   cc.c.opts   : C コンパイラを直接呼ぶもの
# in-tree gmp は configure の --with-pic=yes、in-tree libffi は Debian gcc の既定（PIE）で PIC になる。
# 並列度は依存関係の形で決まるので、序盤（stage0 と stage1 のコンパイラ本体）は
# -j を大きくしても数本しか走らない。rts とライブラリ群に入ると広がる。
RUN JOBS="${BUILD_JOBS:-$(nproc)}" \
    && echo "hadrian jobs: ${JOBS}" \
    && hadrian/build -j"${JOBS}" \
        --flavour="${HADRIAN_FLAVOUR}" --docs="${HADRIAN_DOCS}" \
        "stage1.*.ghc.hs.opts += -fPIC" \
        "stage1.*.ghc.c.opts += -fPIC" \
        "stage1.*.cc.c.opts += -fPIC" \
        binary-dist \
    && mkdir -p /out \
    && cp _build/bindist/ghc-${GHC_VERSION}-x86_64-unknown-linux.tar.xz /out/ \
    && (cd /out && sha256sum ghc-${GHC_VERSION}-x86_64-unknown-linux.tar.xz > SHA256SUMS)

###############################################################################
# 2. bindist: tar.xz だけを取り出すためのステージ
#    docker build --target bindist --output type=local,dest=dist/<codename> .
###############################################################################
FROM scratch AS bindist
COPY --from=builder /out/ /

###############################################################################
# 3. 配布イメージ: slim ベースに bindist を入れ、static-pie が作れることを確かめる
###############################################################################
FROM debian:${DEBIAN_CODENAME}-slim

ARG DEBIAN_CODENAME
ARG GHC_VERSION=9.6.7
ARG CABAL_VERSION=3.12.1.0

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8

# gcc, libc6-dev（rcrt1.o など static-pie 用の起動コードを含む）, binutils は必須。
# g++ は bindist の configure が C++ 標準ライブラリの検出で要求する（無いと configure が失敗する）。
# libgmp-dev / libncurses-dev は、利用側パッケージが -lgmp / -ltinfo を要求したときのため。
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc g++ libc6-dev binutils make pkg-config \
        ca-certificates curl xz-utils git \
        libgmp-dev libncurses-dev zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# --disable-ld-override : GHC の configure は ld.gold / ld.lld があるとそれを選ぶが、
#   gold は gcc の -static-pie が渡す --no-dynamic-linker を知らないため、既定の ld（bfd）を使わせる。
COPY --from=builder /out/ghc-${GHC_VERSION}-x86_64-unknown-linux.tar.xz /tmp/
RUN cd /tmp \
    && tar -xJf "ghc-${GHC_VERSION}-x86_64-unknown-linux.tar.xz" \
    && cd "ghc-${GHC_VERSION}-x86_64-unknown-linux" \
    && ./configure --prefix=/usr/local --disable-ld-override \
    && make install \
    && cd / && rm -rf /tmp/ghc-*

# cabal と ghcup（単体バイナリ）も入れておく
COPY --from=builder /root/.ghcup/cabal/${CABAL_VERSION}/cabal /usr/local/bin/cabal
COPY --from=builder /usr/local/bin/ghcup /usr/local/bin/ghcup

# static-pie 実行ファイルが本当に作れるかを、イメージを作る時点で確かめる。
COPY test/ /usr/local/share/ghc-pie/test/
RUN sh /usr/local/share/ghc-pie/test/check-static-pie.sh

WORKDIR /work
CMD ["ghc", "--interactive"]

# OCI ラベル。ステージの末尾に置き、BUILD_DATE が変わっても上のレイヤのキャッシュを壊さないようにする。
# org.opencontainers.image.source は ghcr.io でパッケージとリポジトリを結び付けるのに使われる。
ARG BUILD_DATE=
ARG IMAGE_SOURCE=https://github.com/khibino/ghc-pie-docker-image
LABEL org.opencontainers.image.title="ghc-pie" \
      org.opencontainers.image.description="GHC ${GHC_VERSION} with every library and RTS object built with -fPIC, so that static-pie executables can be linked (Debian ${DEBIAN_CODENAME})" \
      org.opencontainers.image.version="${GHC_VERSION}-${DEBIAN_CODENAME}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="BSD-3-Clause"
