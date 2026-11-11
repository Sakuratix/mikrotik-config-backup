# mikrotik-config-backup

Ночной экспорт конфигураций MikroTik в git. На выходе история изменений по каждому роутеру: кто, когда и что поменял в firewall, видно через `git log -p core-01.rsc`.

## Как работает

1. По SSH с ключом выполняется `/export show-sensitive=no terse` (пароли и ключи в git не попадают).
2. Строка с датой экспорта вырезается, иначе каждый прогон был бы изменением.
3. Коммит и push только если что-то поменялось. Код выхода 1, если хотя бы один роутер не ответил, чтобы cron или systemd это заметили.

## Установка

```bash
# на каждом роутере: setup-router.rsc (пользователь только на чтение, вход по ключу)
cp routers.example.txt routers.txt
git clone git@github.com:me/net-configs.git /srv/net-configs
BACKUP_REPO=/srv/net-configs ./backup.sh
```

Cron: `15 3 * * * BACKUP_REPO=/srv/net-configs /opt/mikrotik-config-backup/backup.sh`

## Зачем

Когда площадок десятки, фраза «вчера всё работало» без истории конфигов превращается в угадайку. С ней откат занимает минуту: `git show HEAD~1:club-msk-03.rsc`.
