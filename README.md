xapi-script-storage
===================

A xapi storage adapter that calls out to scripts, one script per operation

Design
------

The adapter is a daemon which watches a path /usr/lib/xapi-script-storage/scripts
looking for new directories. For every directory it finds it will register a xapi
service: org.xen.xcp.storage.<name>. When an operation is invoked on this service
it will execute the appropriate script, with the request marshalled as a .json
request on stdin.

