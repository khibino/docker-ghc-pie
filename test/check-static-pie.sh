#!/bin/sh
# PATH 上の ghc で static-pie な実行ファイルを作れることを確かめる。
# Dockerfile のビルド中にも、出来上がったイメージの中でも使える。
set -eu
export LC_ALL=C

here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$here/Main.hs" "$here/TH.hs" "$work/"
cd "$work"

ghc --version
cabal --version | head -1 || true

# ET_DYN で、PT_INTERP も DT_NEEDED も持たないこと = static-pie
check_pie() {
    bin=$1
    readelf -h "$bin" | grep -q 'Type:[[:space:]]*DYN' \
        || { echo "NG: $bin is not ET_DYN (PIE)"; exit 1; }
    if readelf -l "$bin" | grep -q 'INTERP'; then
        echo "NG: $bin has PT_INTERP (not static)"; exit 1
    fi
    if readelf -d "$bin" 2>/dev/null | grep -q 'NEEDED'; then
        echo "NG: $bin has DT_NEEDED (not static)"; exit 1
    fi
    a=$("./$bin" | tail -1)
    b=$("./$bin" | tail -1)
    echo "OK: $bin is static-pie ($a / $b)"
    if [ "$a" = "$b" ]; then
        echo "WARN: load address did not change between runs (ASLR disabled on this kernel?)"
    fi
}

# GHC に同梱の全ライブラリ（.a）に、PIE では使えない絶対 32bit 再配置
# （R_X86_64_32 / R_X86_64_32S）が残っていないことを確かめる。
# .debug_* セクション（DWARF）のものはリンクに影響しないので除く。
echo "--- scan all archives in $(ghc --print-libdir) for non-PIC relocations"
bad=0
for a in $(find "$(ghc --print-libdir)" -name '*.a'); do
    n=$(readelf -r "$a" 2>/dev/null | awk '
        /^Relocation section/ { skip = ($3 ~ /\.rela\.debug_/) }
        !skip && / R_X86_64_32S? / { c++ }
        END { print c + 0 }')
    if [ "$n" != 0 ]; then
        echo "NG: $n non-PIC relocation(s) in $a"; bad=1
    fi
done
[ "$bad" = 0 ] || exit 1
echo "OK: no non-PIC relocations outside .debug_* sections"

echo "--- static-pie (non-threaded rts)"
ghc -O -fPIC -pie -optl-static-pie -outputdir o1 Main.hs -o main-pie
check_pie main-pie

echo "--- static-pie (threaded rts, -rtsopts)"
ghc -O -threaded -rtsopts -fPIC -pie -optl-static-pie -outputdir o2 Main.hs -o main-pie-thr
check_pie main-pie-thr

echo "--- static-pie (profiling rts)"
ghc -O -prof -fprof-auto -fPIC -pie -optl-static-pie -outputdir o3 Main.hs -o main-pie-prof
check_pie main-pie-prof

echo "--- static-pie (debug rts)"
ghc -O -debug -fPIC -pie -optl-static-pie -outputdir o5 Main.hs -o main-pie-dbg
check_pie main-pie-dbg

echo "--- Template Haskell (normal build path)"
ghc -O -outputdir o4 TH.hs -o th
test "$(./th)" = 42

echo "ALL OK"
