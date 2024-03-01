import sqlite3
import json
import urllib

# "https://yyets.dmesg.app/dump/yyets_sqlite.zip"

conn = sqlite3.connect(r"D:\User\Downloads\yyets.sqlite")
cursor = conn.cursor()

movies = []
for i in range(0, 17500, 100):
    cursor.execute(f'SELECT * FROM "main"."yyets" LIMIT {i},100')
    values = cursor.fetchall()
    for movie in values:
        name = movie[1]
        data = json.loads(movie[5])['data']
        if data['info']['channel'] != 'movie':
            continue

        if len(data['list']) < 1:
            continue
        source = data['list'][0]['items']  # 未知：列表作用
        temp = []
        for key, value in source.items():
            if key in ['OST', 'APP', 'RMVB']:
                continue
            try:
                for item in value:
                    for url in item['files']:
                        if url['way_cn'] in ["电驴", "磁力"]:
                            address = urllib.parse.unquote(url['address'], 'utf-8')
                            include = ['双语', '国', '人人影视', '字幕组']
                            exclude = ['.rmvb|', 'Sample', "480P", "480p"]
                            if any(i in address for i in include) and not any(i in address for i in exclude):
                                temp.append(address)
                                # movies.append(address)
                                continue
            except TypeError:
                pass
        if len(temp) >= 1:
            final = temp[0]
            for address in temp:
                include = ['720p', '720P']
                if any(i in address for i in include):
                    final = address
            for address in temp:
                include = ['1080p', '1080P', '1080']
                if any(i in address for i in include):
                    final = address
            movies.append(final)


for i in range(0, len(movies), 1000):
    with open(rf'D:\movie{i+1}-{i+1000}.txt', 'w', encoding='utf-8') as f:
        f.write('\n'.join(movies[i: i + 1000]))

with open(r'D:\movie.txt', 'w', encoding='utf-8') as f:
    f.write('\n'.join(movies))
