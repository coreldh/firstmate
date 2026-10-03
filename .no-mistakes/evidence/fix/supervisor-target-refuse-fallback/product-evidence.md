# Validación del defecto A: identidad del panel o rechazo

Candidato: `06debe10b1bfeda5a0b5c3bcdaf7574e7e933b26`.
Base: `e31bc6e620ca532c2e0e0b72f3fd7c0869a12270`.

Se ejecutaron los comandos reales de Firstmate con hogares desechables marcados por `bin/fm-lab-home.sh`, un servidor tmux privado llamado `fm-lab` y paneles reales de 120 columnas por 40 filas. Ninguna CLI simulada participó en estas comprobaciones del producto. El panel ajeno `firstmate:0` y el panel designado como operador ejecutaban procesos inofensivos; las comprobaciones prueban el descubrimiento, arranque y limpieza del daemon, no entrega de mensajes a un modelo.

## Control de regresión

La base entró con `enter` y `start-native`, por lo que el indicador de ausencia existía. Su daemon real arrancó contra el panel ajeno `firstmate:0` pese a no tener `FM_SUPERVISOR_TARGET`, `TMUX_PANE` ni identidad Herdr:

```text
[2026-10-02T22:13:49-0600] daemon starting (pid 84443); target=firstmate:0; target_source=FALLBACK(firstmate:0); backend=tmux; backend_source=FALLBACK(tmux); afk=on; inject_skip='heartbeat'; stale_escalate=240s; batch=90s
[2026-10-02T22:13:51-0600] daemon shutting down
```

## Rechazo del candidato

El descubrimiento ejecutado devolvió exactamente 1 y cero bytes de stdout sin identidad, incluso con un identificador Herdr incompleto. El daemon rechazó dos arranques consecutivos en el mismo hogar, con código 1, sin registrar `daemon starting`, y sin PID ni bloqueo restantes. El contenido del panel ajeno quedó idéntico.

```text
error: away-mode pane escalation unavailable: no operator pane handle (target_source=UNAVAILABLE; no FM_SUPERVISOR_TARGET, TMUX_PANE, or HERDR_ENV+HERDR_PANE_ID); refusing to arm - set FM_SUPERVISOR_TARGET and FM_SUPERVISOR_BACKEND to firstmate's own pane
```

Registro duradero tras ambos intentos:

```text
[2026-10-02T22:13:51-0600] startup refused: away-mode pane escalation unavailable; target_source=UNAVAILABLE; backend_source=FALLBACK(tmux)
[2026-10-02T22:13:51-0600] startup refused: away-mode pane escalation unavailable; target_source=UNAVAILABLE; backend_source=FALLBACK(tmux)
```

`fm-afk-launch.sh start` rechazó también dos intentos. Conservó los bytes del registro de ausencia y no creó indicador `.afk`, terminal, PID ni bloqueo:

```text
[2026-10-02T22:13:52-0600] startup refused: away-mode pane escalation unavailable; target_source=UNAVAILABLE; refused_by=fm-afk-launch start
[2026-10-02T22:13:52-0600] startup refused: away-mode pane escalation unavailable; target_source=UNAVAILABLE; refused_by=fm-afk-launch start
```

## Identidades y condiciones previas

Un destino explícito, un destino explícito sin transporte configurado, y un `TMUX_PANE` real arrancaron el daemon. Un destino explícito prevaleció sobre el otro panel real heredado. La terminación liberó el PID y el bloqueo.

```text
[2026-10-02T22:13:54-0600] daemon starting (pid 93780); target=%1; target_source=FM_SUPERVISOR_TARGET; backend=tmux; backend_source=FM_SUPERVISOR_BACKEND; afk=off; inject_skip='heartbeat'; stale_escalate=240s; batch=90s
[2026-10-02T22:13:55-0600] daemon shutting down
[2026-10-02T22:13:55-0600] daemon starting (pid 96650); target=%1; target_source=FM_SUPERVISOR_TARGET; backend=tmux; backend_source=FALLBACK(tmux); afk=off; inject_skip='heartbeat'; stale_escalate=240s; batch=90s
[2026-10-02T22:13:56-0600] daemon shutting down
[2026-10-02T22:13:57-0600] daemon starting (pid 99642); target=%1; target_source=TMUX_PANE; backend=tmux; backend_source=TMUX_PANE; afk=off; inject_skip='heartbeat'; stale_escalate=240s; batch=90s
[2026-10-02T22:13:58-0600] daemon shutting down
```

El launcher creó y detuvo el daemon real en un terminal separado. La geometría e identidad del panel designado como operador quedaron idénticas. Las condiciones de registro ausente, retorno pendiente y supervisión alternativa habilitada rechazaron antes de intentar el descubrimiento del panel.

La secuencia real `enter → start-native → fm-afk-start.sh` reprodujo la limitación aceptada: el daemon rechazó con `UNAVAILABLE` y liberó su propiedad, pero `.afk` y el registro `none / native` permanecieron hasta ejecutar `stop`. Esto prueba esa secuencia de comandos; no se usó la herramienta de segundo plano de Claude o Grok ni se evaluó el guard de fin de turno.

## Herdr no probado en vivo

El helper obligatorio rechazó `prepare`:

```text
exit=1
fm-herdr-lab: fleet-state tripwire requires exactly one running default session
```

No se creó una sesión Herdr. El contrato requiere una sesión `default` activa como control de seguridad antes de `provision`; esta fase no puede arrancar ni alterar `default`. El operador puede aportar esa sesión y repetir. Las pruebas seleccionadas ejecutaron el contrato de composición y prioridad Herdr y su arranque con transporte simulado; esa evidencia no se cuenta como Herdr en vivo.

## Comprobaciones y limpieza

Se ejecutaron cuatro funciones conductuales seleccionadas de `tests/fm-daemon.test.sh` y tres de `tests/fm-afk-launch.test.sh`. Todas terminaron con código 0; esa selección no cubre la suite completa ni sustituye CI.

Los hogares, procesos y sockets desechables se retiraron. El transcript JSON contiene comandos, salidas, códigos de retorno y copias del estado generado. No se modificó código del proyecto. No se capturó una interfaz gráfica porque el cambio validado afecta comandos y registros de arranque.
