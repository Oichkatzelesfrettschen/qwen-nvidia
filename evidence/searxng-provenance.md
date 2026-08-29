# SearXNG and YaCy native install provenance

This file is a template. `remote/install-searxng.sh` and `remote/install-yacy.sh`
run on the laptop, not on the workstation this tree is edited from, so every
field below reads `-` until a laptop run fills it in. A field left `-` after a
run states that the run did not reach that check; it is never filled with an
assumed or predicted value.

## SearXNG

```text
upstream:            https://github.com/searxng/searxng.git
pinned commit:        a30b2d47492ab46ae82ce25ee62a31626565cf67
commit read date:     2026-08-28 (searxng/searxng carries no tags at that date)
install root:         /opt/searxng-qwen-apu (world-readable; the searxng
                      user's searxng-src stage refuses a source under a
                      0750 home directory)
installer log sha256: 2cece232571116ebd70736fd3e38e44f14769f33059474feed31bb080f217d44
settings source:      remote/searxng-settings.yml
settings sha256:      fde41eb1b357f340b1397c3a25e2e0fd63b087bd7f38ac63d40c1d1dbe8d14be
installed settings:   /etc/searxng/settings.yml (0640 searxng:searxng)
listener:             127.0.0.1:8888 alone (2026-08-29)
GET /search?q=test&format=json: 200, parseable JSON body
GET /config:          200; every qwen-* category present with its engines
```

### Confirmed engine table (read from the pinned commit's own
`searx/settings.yml`, `searx/engines/*.py`, and `searx/engines/__init__.py`
before any file in this repository was written; every name below appears in
that tree)

| Category | Engine | Upstream default | This instance |
| --- | --- | --- | --- |
| qwen-open | mwmbl | disabled | enabled |
| qwen-open | wiby | disabled | enabled |
| qwen-open | wikipedia | enabled | enabled |
| qwen-open | wikidata | enabled | enabled |
| qwen-broad | google | disabled | enabled |
| qwen-broad | bing | disabled | enabled |
| qwen-broad | brave | enabled | enabled |
| qwen-broad | duckduckgo | enabled | enabled |
| qwen-broad | startpage | enabled | enabled |
| qwen-broad | qwant | disabled | enabled |
| qwen-broad | mojeek | disabled | enabled |
| qwen-academic | crossref | disabled | enabled |
| qwen-academic | arxiv | enabled | enabled |
| qwen-academic | pubmed | enabled | enabled |
| qwen-academic | wikipedia | enabled | enabled |
| qwen-news | reuters | enabled | enabled |
| qwen-news | google news | enabled | enabled |
| qwen-news | bing news | enabled | enabled |
| qwen-news | brave.news | enabled | enabled |
| qwen-yacy | yacy | disabled | enabled |

`braveapi` is a distinct, key-gated engine the pinned tree also ships; this
instance enables `brave` (the web engine) and leaves `braveapi` untouched at
its upstream default. Every engine name above was verified present in the
pinned tree; none were guessed.

### Live verification (`remote/install-searxng.sh` fills this after a real run)

```text
verified engine table (2026-08-29, /config membership read by the installer):
qwen-open	mwmbl	enabled=True
qwen-open	wikidata	enabled=True
qwen-open	wiby	enabled=True
qwen-open	wikipedia	enabled=True
qwen-broad	mojeek	enabled=True
qwen-broad	startpage	enabled=True
qwen-broad	duckduckgo	enabled=True
qwen-broad	google	enabled=True
qwen-broad	brave	enabled=True
qwen-broad	bing	enabled=True
qwen-broad	qwant	enabled=True
qwen-academic	wikipedia	enabled=True
qwen-academic	pubmed	enabled=True
qwen-academic	arxiv	enabled=True
qwen-academic	crossref	enabled=True
qwen-news	bing news	enabled=True
qwen-news	brave.news	enabled=True
qwen-news	google news	enabled=True
qwen-news	reuters	enabled=True
qwen-yacy	yacy	enabled=True
```

Two laptop facts moved the installer before this run verified. The upstream
`searxng-src` stage clones the pinned tree as the `searxng` system user and
its readability check refuses a source under a home directory at mode 0750,
so the install root lives under `/opt`, and `utils/brand.sh` reads settings
through a bare `python`, which `python-is-python3` supplies on the appliance.
`remote/searxng-control.sh` opens the server log inside the service-user shell,
because the run directory is `searxng`-owned and the invoking human cannot
create a file there.

### Live category queries (2026-08-29, both services up, one query each)

`GET /search?q=llama.cpp+vulkan&format=json&categories=CATEGORY` from the
laptop's loopback, results counted after SearXNG's own merge; `unresponsive`
is the instance's own per-engine report.

| Category | HTTP | results | engines answering | unresponsive |
| --- | ---: | ---: | --- | --- |
| qwen-open | 200 | 1 | wiby 1 | mwmbl timeout |
| qwen-broad | 200 | 16 | bing 10, qwant 10, google 10 | brave too many requests; duckduckgo CAPTCHA; startpage CAPTCHA |
| qwen-academic | 200 | 40 | crossref 20, pubmed 20 | arxiv timeout |
| qwen-news | 200 | 10 | google news 10 | bing news parsing error; brave.news suspended |
| qwen-yacy | 200 | 0 | -- | yacy unexpected crash (before `enable_http`) |

crossref answered inside the 8 s `max_request_timeout`, which settles the
interaction the section below registers as open. The `qwen-yacy` row
failed with `httpx.UnsupportedProtocol`: `searx/network` refuses a plain
`http://` engine URL unless the engine block carries `enable_http: true`,
which the checked-in settings file now sets for the http-only local peer.
With that key installed, `qwen-yacy` alone at `search_mode: global`
returned 10 results for "wikipedia" (de, mi, and en Wikipedia pages from
the world index) and 0 for "llama.cpp vulkan", with an empty
`unresponsive` list and zero `searx.engines.yacy` warnings in the server
log; the second count reads the peer index's coverage rather than a fault.
A profile that names `qwen-open` as its primary category meets
`minimum_results` through `qwen-broad` as its fallback on this evidence,
since the open index answered one result where the broad category answered
sixteen.

## YaCy

```text
upstream:                   https://github.com/yacy/yacy_search_server.git
pinned tag:                 Release_1.941
pinned commit:               f0464e7fbcfcb69127f0325910f92f113ce23677
tag read date:               2026-08-28 (git ls-remote --tags --sort=-v:refname)
release tarball SHA-256:     -  (not confirmed; see "could not confirm" below)
install directory:           $HOME/opt/yacy
build command:                ant clean all
build log sha256:             9adef1b9899fa7ed60f8c80cec0ea067f108e75878d3c2daf37bfd73de62a181
yacy.conf sha256:             4847346446e001d062e7e3540471393f1245110499904b805f25f63d572e311c
listener:                     127.0.0.1:8090 alone, reported by ss in the
                              dual-stack form [::ffff:127.0.0.1]:8090 (2026-08-29)
java major version measured:  21 (openjdk 21.0.12)
```

The JVM opens one dual-stack socket, so `ss -ltn` prints the IPv4 loopback
as `[::ffff:127.0.0.1]:8090`; `remote/yacy-control.sh` and
`remote/install-yacy.sh` read that spelling as the loopback listener, and the
control script matches listener strings as fixed text because a bracketed
address read as a regular expression is a character class. A cold start on
the two 2.3 GHz cores opened the listener 6 s after launch with the tree
alone and past 60 s beside a running compile, so the installer waits 300 s.
The peer joins the `freeworld` network as a junior member: `upnp.enabled`
is false and the bind is loopback, so it publishes its seed outward and
accepts no inbound peer connection.

## Could not confirm

- A published SHA-256 for a YaCy release tarball or binary distribution. YaCy
  publishes releases at `download.yacy.net`, which sits outside this task's
  network allowance of `github.com` and `docs.searxng.org`. `install-yacy.sh`
  pins the release tag's own commit (a git SHA-1, read from `github.com` with
  `git ls-remote --tags`) and builds from that pinned source with
  `ant clean all`, the path `yacy_search_server`'s own `README.md` documents,
  rather than downloading a tarball whose checksum this run never read. A
  tarball SHA-256 stays `-` above rather than an invented value.
- Any `reuters` API-key or subscription requirement at request time. The
  engine module `searx/engines/reuters.py` is present and enabled with no
  `disabled: true` in the pinned `searx/settings.yml`, which is what admits
  it to `qwen-news`; whether a live request against it succeeds without
  further credentials is unconfirmed until a laptop run's `GET /config` and a
  live search both return.

## Known interaction: crossref's per-engine timeout against max_request_timeout

`searx/search/__init__.py`'s `_get_requests` sets `actual_timeout =
min(default_timeout, max_request_timeout)`, where `default_timeout` is the
max of every selected engine's own `timeout`. `crossref`'s block in the
pinned `searx/settings.yml` carries `timeout: 30`, which this instance's
`max_request_timeout: 8.0` caps to 8 seconds regardless. A crossref query
that upstream expected to need up to 30 seconds routinely times out under
this instance's outgoing tuple; this is a consequence of the design facts
this file was built from, not a bug in `remote/searxng-settings.yml`, and a
laptop run's live search against `qwen-academic` should confirm whether 8
seconds is enough in practice.
