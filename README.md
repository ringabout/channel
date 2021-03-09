# channel
Upcoming Nim channel implementation for ORC(the development is moved to https://github.com/nim-lang/Nim/pull/17305)

## a motivate example
```nim
import channel
import std/[httpclient, isolation, json]


var ch = initChan[JsonNode](kind = Spsc)


proc download(client: HttpClient, url: string) =
  let response = client.get(url)
  echo "content: "
  echo response.body[0 .. 20]

proc worker =
  var client = newHttpClient()
  var data: JsonNode
  ch.recv(data)
  if data != nil:
    for url in data["url"]:
      download(client, url.getStr)
  client.close()

proc prepareTasks(fileWithUrls: string): seq[Isolated[JsonNode]] =
  result = @[]
  for line in lines(fileWithUrls):
    result.add isolate(parseJson(line))

proc spawnCrawlers =
  var tasks = prepareTasks("todo_urls.txt")
  for t in mitems tasks:
    ch.send move t # or ch.send t.extract

var thr: Thread[void]
createThread(thr, worker)

spawnCrawlers()
joinThread(thr)
```

## Useful materials
https://github.com/nim-lang/RFCs/issues/244
