# KOPrinter: print to your KOReader screen

Exposes a KOReader device as an IPP printer on the local network. Add it on a
computer or phone like any other printer, print a document, and it opens in
KOReader.

The printer's page is the screen: a 1072 x 1448 pixel screen at 300 dpi is
advertised as a 90.76 x 122.6 mm sheet with a 1 mm margin (or borderless), so
that every printed page is exactly one screenful, with no scaling and no
wasted space. Monochrome screens are reported as monochrome, colour screens
as colour.

Only PDF is accepted, on purpose: KOReader renders PDF natively and better
than any raster format the printer could receive instead.

## Installation

Copy both `KOPrinter.koplugin` and `mDNS.koplugin` into the `plugins`
directory of your KOReader installation (`/mnt/us/koreader/plugins/` on a
Kindle) and restart KOReader. The mDNS responder plugin is what makes the
printer appear in printer lists; KOPrinter registers its service with it.

The menu entry is in **Network ▸ KOPrinter (IPP printer)**:

- **Enable KOPrinter**: master switch, on by default.
- Status line: tap it for the page size, address and counters.
- **Printer name**: what the printer list shows, `KOReader on <model>` by default.
- **Port**: 631 by default; 8631 is used when that one cannot be bound.
- **Open received documents immediately**: on by default. When off, an incoming
  document is only announced and stays in the spool folder.

Received documents are saved under `KOPrinter/` in the KOReader library
folder (`/mnt/us/documents/KOPrinter/` on a Kindle), named after the date and
the job title.

A `Toggle KOPrinter` action is available for gestures and profiles.

## Printing from a computer

macOS finds the printer by itself: *System Settings ▸ Printers & Scanners ▸
Add Printer*, pick it from the list, and macOS builds a driverless queue from
the attributes the printer reports. From the command line:

```sh
ippfind                                                    # lists it
lpadmin -p KOReader -E -v ipp://kindlebasic4.local:631/ipp/print -m everywhere
lp -d KOReader document.pdf
```

Linux with CUPS works the same way (`cups-browsed` or `lpadmin -m everywhere`).

## What it implements

- IPP 1.1 and 2.0 over HTTP (RFC 8010, RFC 8011): `Print-Job`, `Validate-Job`,
  `Create-Job` / `Send-Document`, `Get-Jobs`, `Get-Job-Attributes`,
  `Cancel-Job`, `Cancel-My-Jobs`, `Close-Job`, `Get-Printer-Attributes` and
  `Identify-Printer`, with the attribute set a driverless client needs,
  including `media-col-database`.
- `Content-Length` and chunked request bodies, `Expect: 100-continue`,
  keep-alive connections.
- Documents are streamed to the spool file as they arrive, never buffered in
  memory.
- A `GET /` on the printer port returns a small status page.

## How it works inside KOReader

The TCP server registers itself with `UIManager:insertZMQ()`, so the main
loop polls it every few milliseconds without ever blocking, and a document
being transferred does not freeze the UI. The server survives document
switches (plugins are re-instantiated on every document load) and reacts to
`NetworkConnected`, `NetworkDisconnecting`, `Suspend`, `Resume`,
`EnterStandby` and `LeaveStandby` events.

On Kindles the firewall drops incoming TCP by default, so the plugin inserts
an `iptables` rule accepting its port on `wlan0` while it runs, and removes it
when it stops.

The `_ipp._tcp` service is declared to the mDNS responder plugin through the
`MDNSCollectServices` event, and withdrawn (with a goodbye packet) when the
server stops.

## Testing

Unit tests run with LuaJIT and need LuaSocket and LuaFileSystem
(`luarocks --lua-version=5.1 install luasocket luafilesystem`):

```sh
luajit tests/test_ipp_message.lua
luajit tests/test_main.lua          # starts the plugin on a real socket and prints to it
```

The printer can run on its own, outside KOReader, and be exercised with the
IPP tools shipped with CUPS. On a computer the system already owns port 5353,
so the Bonjour announcement is made with `dns-sd` (the tool prints the exact
command):

```sh
luajit tools/standalone.lua 8631 /tmp/koprinter
ipptool -tv -f document.pdf ipp://127.0.0.1:8631/ipp/print \
    /usr/share/cups/ipptool/ipp-2.0.test
```

## Tested on

| | |
| --- | --- |
| Client | macOS 26.6.2, CUPS 2.3.4 |
| Conformance | `ipptool` suites `ipp-1.1` 24/24, `ipp-2.0` 25/25, `ipp-everywhere` 25/26 (the miss is the JPEG and PWG Raster formats, which this printer deliberately does not offer) |
| Driverless | `lpadmin -m everywhere` builds a queue whose default page is the screen size; `lp` delivers a PDF whose page is exactly the screen |

## Limitations

- PDF only. Clients that insist on Apple Raster (URF) do not see the printer:
  iOS AirPrint requires URF, macOS does not.
- No TLS (`ipps`): the printer is meant for a home network.
- One document per job (`multiple-document-jobs-supported` is false).
- The printer is unreachable while the device sleeps, since Wi-Fi is off.
