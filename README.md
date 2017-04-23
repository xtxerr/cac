# APIC-ReST-2-OpenNMS

Various things to integrate Cisco's ACI into OpenNMS via ReST.

- Alarming and Event Notifications via OpenNMS's eventd.
- Interface Accounting grouped by APIC types.

- All ReST calls are done in non-blocking fashion via Mojo's event loop.
- Needs to be executed periodically, eg. cron.
