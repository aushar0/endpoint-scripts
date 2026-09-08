Payload goes here at build time:
  robocopy <extracted-package>r99\Drivers .\Drivers /E
The installer stages every INF under .\Drivers recursively (both ARL/LNL variants ship; Windows binds only matching HWIDs).
