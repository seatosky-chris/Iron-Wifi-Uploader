# Iron Wifi Uploader

This script will get a list of members from a database and then will upload them to Iron Wifi to create guest logins for each member. It can be scheduled using task scheduler to periodically update the guest wifi logins.

Be sure to edit the `$DBConnString`, `$APIKey`, and `$MemberQuery` fields first to get this to work.