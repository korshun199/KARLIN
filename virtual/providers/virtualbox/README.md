# VirtualBox provider

Провайдер создаёт загрузочный ISO и виртуальную машину VirtualBox.

Виртуальная машина — только средство запуска гостя из `virtual/guest/`.
Настройки VirtualBox не являются частью KARLIN Socket.

Перед запуском можно проверить хост:

```sh
./virtual/providers/virtualbox/check-host.sh
```

Для сборки ISO нужны `grub-mkrescue`, `xorriso`, `mtools`, `cpio` и `gzip`.
На Ubuntu/Debian пакет с командой `mformat` называется `mtools`.
