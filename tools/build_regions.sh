#!/bin/bash
# 地域ランキング用の境界データ（FogViewer/Resources/regions.bin）を作る。
#
# 使い方: tools/build_regions.sh <作業フォルダ>
#   作業フォルダに次のデータを展開しておく（どちらも手で取得する）。
#   - ne/ne_10m_admin_0_countries.shp
#       Natural Earth 1:10m Admin 0 – Countries（パブリックドメイン）
#       https://naciscdn.org/naturalearth/10m/cultural/ne_10m_admin_0_countries.zip
#   - n03/N03-20260101.shp, n03/N03-20260101_prefecture.shp
#       国土数値情報 行政区域データ（N03, 2026 年 1 月 1 日時点）。出典の表示が必要
#       https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N03-2026.html
#
# 必要なもの: node（npx で mapshaper を使う）、python3
set -euo pipefail

WORK=${1:?作業フォルダを指定してください}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/../FogViewer/Resources/regions.bin"
MS=(npx -y mapshaper@0.6)
cd "$WORK"

# 市区町村：行政区域コードごとにまとめて面積を測ってから簡略化する（隣との境は共有したまま縮む）
"${MS[@]}" -i n03/N03-20260101.shp \
  -filter 'N03_007 != ""' \
  -dissolve N03_007 copy-fields=N03_001,N03_004,N03_005 \
  -each 'area_km2 = this.area / 1e6' \
  -simplify interval=50 keep-shapes \
  -o munis.json format=geojson precision=0.000001

# 政令指定都市：区を市ごとにまとめる（強調表示の輪郭用）
"${MS[@]}" -i munis.json \
  -filter 'N03_005 != ""' \
  -dissolve N03_001,N03_004 sum-fields=area_km2 \
  -o cities.json format=geojson precision=0.000001

# 都道府県（強調表示の輪郭用。面積は市区町村の合計を使う）
"${MS[@]}" -i n03/N03-20260101_prefecture.shp \
  -filter 'N03_007 != ""' \
  -dissolve N03_001 \
  -simplify interval=150 keep-shapes \
  -o prefs.json format=geojson precision=0.000001

# 国
"${MS[@]}" -i ne/ne_10m_admin_0_countries.shp \
  -each 'area_km2 = this.area / 1e6' \
  -simplify interval=1000 keep-shapes \
  -filter-fields ADM0_A3,NAME_JA,NAME,CONTINENT,SUBREGION,ISO_A2_EH,area_km2 \
  -o countries.json format=geojson precision=0.00001

python3 "$HERE/regions_to_bin.py" countries.json prefs.json cities.json munis.json "$OUT"
ls -l "$OUT"
