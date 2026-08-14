# KARLIN VM 0

Первая виртуальная испытательная машина KARLIN. Она запускает настоящее
Linux-ядро в QEMU и минимальный initramfs с приглашением `> `.

## Запуск

```sh
./virtual/qemu/run.sh
```

Если ядро находится не в стандартном месте:

```sh
KARLIN_KERNEL=/путь/к/читаемому/vmlinuz ./virtual/qemu/run.sh
```

Внутри доступны базовые команды:

```text
> uname
> ls /bin
> poweroff
```

Выход из QEMU без выключения виртуальной машины: `Ctrl-a`, затем `x`.
