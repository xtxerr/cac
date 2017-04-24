# APIC-ReST-2-OpenNMS

Cisco APIC poller, which collects all sorts of data in non-blocking fashion, if needed, on multiple controllers in parallel. Creates statistics for OpenNMS collectd and sends events via raw TCP to OpenNMS eventd. 

- Alarming and Event Notifications via OpenNMS's eventd.
- Interface Accounting grouped by APIC types.
- All ReST calls are done in non-blocking fashion via Mojo's event loop.
- Needs to be executed periodically, eg. cron.
- Creates XML files for OpenNMS collectd's XML collector.



# License and Copyright

Copyright 2017 Christian Meutes <christian@errxtx.net>


Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

  http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
