# Run once on each router: a read-only user that can only log in with a key.
/user group add name=backup policy=ssh,read,sensitive,!write,!policy,!test,!winbox,!web,!api,!ftp,!reboot,!romon
/user add name=backup group=backup password=[:rndstr length=32]
# then: /user ssh-keys import public-key-file=backup.pub user=backup
/ip service set ssh address=10.0.0.0/8
