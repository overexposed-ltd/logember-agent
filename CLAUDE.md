# logember-agent

Публично репо. Тук НЯМА нищо от hub-а, ingest-а или клиентите: само install скрипт, OTel Collector конфигурация, systemd unit и build скрипт.

- README, коментарите и commit съобщенията на английски (клиентите ги четат). Отговаряй на собственика на български.
- Не пиши собствен collector. Всяка функционалност първо се търси като готов OTel компонент (receiver/processor/exporter); custom Go код само ако няма такъв, и тогава в `internal/`.
- Схемата на реда и OTLP атрибутите (`logember.service`, `logember.env`) трябва да съвпадат с `proto/log-schema.json` в монорепото `logember`. Промяна там → PR тук, свързан в описанието.
- `install.sh` трябва да е безопасен за `curl | sh`: `set -euo pipefail`, проверка на checksum на бинарния файл, нищо не се изпълнява от интернет освен самия бинарен файл.
- Без commit директно в `main`; feature клон + PR. Всеки PR описва как е тестван (на коя дистрибуция, `systemctl status`, първите редове в hub-а).
- Версии: semver тагове `v0.x.y`; GitHub Release с бинарни файлове за linux/amd64 и linux/arm64 + `checksums.txt`.
