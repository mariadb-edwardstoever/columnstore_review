# Columnstore Review
Review MariaDB Columnstore for Support
```
This script is intended to be run while logged in as root.
If database is up, this script will connect as root@localhost via socket.

Switches:
   --help            # display this message
   --logs            # create a compressed archive of logs for MariaDB Support Ticket
   --backupdbrm      # takes a compressed backup of extent map files in dbrm directory
   --testschema      # creates a test schema, tables, imports, queries, drops schema
   --emptydirs       # searches /var/lib/columnstore for empty directories
   --notmysqldirs    # searches /var/lib/columnstore for directories not owned by mysql
   --emcheck         # Checks the extent map for orphaned and missing files
   --pscs            # Adds the pscs command. pscs lists running columnstore processes

Color output switches:
   --color=none      # print headers without color
   --color=red       # print headers in red
   --color=blue      # print headers in blue
   --color=green     # print headers in green
   --color=yellow    # print headers in yellow
   --color=magenta   # print headers in magenta
   --color=cyan      # print headers in cyan (default color)
   --color=lred      # print headers in light red
   --color=lblue     # print headers in light blue
   --color=lgreen    # print headers in light green
   --color=lyellow   # print headers in light yellow
   --color=lmagenta  # print headers in light magenta
   --color=lcyan     # print headers in light cyan
```
