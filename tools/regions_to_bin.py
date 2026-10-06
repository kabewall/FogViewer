"""簡略化した境界（GeoJSON）を、アプリが読む regions.bin にまとめる。

形式（リトルエンディアン）:
  "FVRG", u32 版, u32 地域数
  地域ごと: u8 階層, i32 親の番号（なければ -1）, 文字列 コード, 文字列 名前,
           文字列 まとまり（国なら小地域、都道府県なら地方）, 文字列 国旗用の ISO 3166-1 alpha-2,
           f64 面積 km², u32 輪の数, 輪ごとに u32 点の数と (i32 経度×1e6, i32 緯度×1e6) の並び
  文字列: u16 バイト数 + UTF-8
階層: 0 国, 1 都道府県, 2 政令指定都市, 3 市区町村（政令指定都市の区を含む）, 4 大陸（輪なし）
輪は外周と穴を区別せず並べる（偶奇規則で内外を判定する）。
"""
import json
import struct
import sys

VERSION = 2
COUNTRY, PREFECTURE, CITY, MUNICIPALITY, CONTINENT = 0, 1, 2, 3, 4

# Natural Earth の CONTINENT → (コード, 名前)。並びは世界の霧のパスポートに近づける
CONTINENTS = {
    "Asia": ("AS", "アジア"),
    "Europe": ("EU", "ヨーロッパ"),
    "Africa": ("AF", "アフリカ"),
    "North America": ("NA", "北アメリカ"),
    "South America": ("SA", "南アメリカ"),
    "Oceania": ("OC", "オセアニア"),
    "Antarctica": ("AN", "南極"),
    "Seven seas (open ocean)": ("SS", "大洋の島々"),
}

SUBREGIONS = {
    "Eastern Africa": "東アフリカ", "Middle Africa": "中部アフリカ", "Northern Africa": "北アフリカ",
    "Southern Africa": "南部アフリカ", "Western Africa": "西アフリカ", "Antarctica": "南極",
    "Central Asia": "中央アジア", "Eastern Asia": "東アジア", "South-Eastern Asia": "東南アジア",
    "Southern Asia": "南アジア", "Western Asia": "西アジア",
    "Eastern Europe": "東ヨーロッパ", "Northern Europe": "北ヨーロッパ",
    "Southern Europe": "南ヨーロッパ", "Western Europe": "西ヨーロッパ",
    "Caribbean": "カリブ", "Central America": "中央アメリカ", "Northern America": "北アメリカ",
    "South America": "南アメリカ", "Australia and New Zealand": "オーストラリア・NZ",
    "Melanesia": "メラネシア", "Micronesia": "ミクロネシア", "Polynesia": "ポリネシア",
    "Seven seas (open ocean)": "大洋の島々",
}

# 都道府県コードの上 2 桁 → 地方
def chiho(code):
    n = int(code)
    for last, name in [(1, "北海道"), (7, "東北"), (14, "関東"), (23, "中部"), (30, "近畿"),
                       (35, "中国"), (39, "四国"), (47, "九州・沖縄")]:
        if n <= last:
            return name


def rings(geometry):
    if geometry is None:
        return []
    polys = [geometry["coordinates"]] if geometry["type"] == "Polygon" else geometry["coordinates"]
    out = []
    for poly in polys:
        for ring in poly:
            if len(ring) > 1 and ring[0] == ring[-1]:
                ring = ring[:-1]
            if len(ring) >= 3:
                out.append(ring)
    return out


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)["features"]


def main(countries_path, prefs_path, cities_path, munis_path, out_path):
    regions = []  # (level, parent, code, name, group, flag, area, rings)

    def add(level, parent, code, name, area, geometry, group="", flag=""):
        regions.append((level, parent, code, name, group, flag, area, rings(geometry)))
        return len(regions) - 1

    countries = load(countries_path)
    continent_index = {}
    for key, (code, name) in CONTINENTS.items():
        area = sum(f["properties"]["area_km2"] for f in countries if f["properties"]["CONTINENT"] == key)
        continent_index[key] = add(CONTINENT, -1, code, name, area, None)

    japan = None
    for f in sorted(countries, key=lambda f: f["properties"]["ADM0_A3"]):
        p = f["properties"]
        flag = p["ISO_A2_EH"] if len(p["ISO_A2_EH"]) == 2 else ""
        i = add(COUNTRY, continent_index[p["CONTINENT"]], p["ADM0_A3"], p.get("NAME_JA") or p["NAME"],
                p["area_km2"], f["geometry"], group=SUBREGIONS[p["SUBREGION"]], flag=flag)
        if p["ADM0_A3"] == "JPN":
            japan = i
    assert japan is not None, "日本が見つかりません"

    munis = sorted(load(munis_path), key=lambda f: f["properties"]["N03_007"])
    pref_area = {}
    pref_code = {}
    for f in munis:
        p = f["properties"]
        pref_area[p["N03_001"]] = pref_area.get(p["N03_001"], 0) + p["area_km2"]
        pref_code.setdefault(p["N03_001"], p["N03_007"][:2])

    pref_index = {}
    for f in sorted(load(prefs_path), key=lambda f: pref_code[f["properties"]["N03_001"]]):
        name = f["properties"]["N03_001"]
        pref_index[name] = add(PREFECTURE, japan, pref_code[name], name, pref_area[name], f["geometry"],
                               group=chiho(pref_code[name]))

    # 政令指定都市のコードは、区のコードのうち最小のものの下 1 桁を 0 にしたもの（例: 札幌市 01100、浜松市 22130）
    city_code = {}
    for f in munis:
        p = f["properties"]
        if p["N03_005"]:
            key = (p["N03_001"], p["N03_004"])
            city_code[key] = min(city_code.get(key, "99999"), p["N03_007"][:4] + "0")
    city_index = {}
    for f in sorted(load(cities_path), key=lambda f: city_code[(f["properties"]["N03_001"], f["properties"]["N03_004"])]):
        p = f["properties"]
        key = (p["N03_001"], p["N03_004"])
        city_index[key] = add(CITY, pref_index[p["N03_001"]], city_code[key], p["N03_004"], p["area_km2"], f["geometry"])

    for f in munis:
        p = f["properties"]
        if p["N03_005"]:
            parent, name = city_index[(p["N03_001"], p["N03_004"])], p["N03_005"]
        else:
            parent, name = pref_index[p["N03_001"]], p["N03_004"]
        add(MUNICIPALITY, parent, p["N03_007"], name, p["area_km2"], f["geometry"])

    def text(s):
        b = s.encode("utf-8")
        return struct.pack("<H", len(b)) + b

    points = 0
    with open(out_path, "wb") as out:
        out.write(b"FVRG" + struct.pack("<II", VERSION, len(regions)))
        for level, parent, code, name, group, flag, area, rs in regions:
            out.write(struct.pack("<Bi", level, parent) + text(code) + text(name) + text(group) + text(flag)
                      + struct.pack("<dI", area, len(rs)))
            for ring in rs:
                out.write(struct.pack("<I", len(ring)))
                out.write(b"".join(struct.pack("<ii", round(x * 1e6), round(y * 1e6)) for x, y, *_ in ring))
                points += len(ring)
    counts = [sum(1 for r in regions if r[0] == level) for level in range(5)]
    print(f"大陸 {counts[4]}・国 {counts[0]}・都道府県 {counts[1]}・政令指定都市 {counts[2]}・市区町村 {counts[3]}、点 {points:,}")


if __name__ == "__main__":
    main(*sys.argv[1:6])
