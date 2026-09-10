local _ = require("gettext")
return {
    fullname = _("KOPrinter"),
    description = _([[Exposes the screen as an AirPrint-style IPP printer on the local network, so that printing from a computer or a phone opens the document in KOReader. Requires the mDNS responder plugin to be discoverable.]]),
}
