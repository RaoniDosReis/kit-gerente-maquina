---
name: controle-termico
description: Controle térmico da CI local: por que a CI esquenta a máquina, o perfil da CI, o teto de desempenho que sobe e desce pela temperatura, ventoinhas, cascata de perfis, reposição na saída, relatórios de tendência, adaptação a outro hardware, permissões de /sys e o caso Windows (WSL2). Use ao montar, ajustar ou depurar o ci-termica e ao receber uma escalação de temperatura ou ventoinhas.
---

# Controle térmico da CI local

Esta skill é a **receita**: o que a peça faz, por que existe, as regras e os limiares, e como o gerente a monta do zero ou a adapta.
Os scripts em `scripts/` são a implementação de referência já generalizada; se o hardware for outro, adapte-os por estas regras.

## Por que existe
Um executor de CI local (por exemplo o GitHub Actions self-hosted) roda vários jobs pesados de uma vez: testes, builds, contêineres.
Em notebook, a CPU passa de 95 °C, o processador se segura (a frequência cai) e os jobs ficam mais lentos e instáveis do que ficariam
com um teto de desempenho moderado. Num computador de mesa o problema é menor, mas a regra serve igual. O objetivo é achar o **teto
de desempenho estável** (o ponto em que a máquina não esquenta além do limite), sem ninguém mexer à mão, e **devolver a máquina ao
estado normal** quando a CI acaba.

## Peças
| Peça | O que faz |
|---|---|
| `scripts/ci-termica.sh` (serviço `ci-termica`) | Detecta a CI, aplica o perfil, ajusta o teto pela temperatura, mantém as ventoinhas, repõe na saída. |
| `scripts/temperatura.sh` | Imprime `cpu_pacote cpu_max_nucleo mhz_medio gpu` pelo kernel (coretemp, k10temp ou x86_pkg_temp; nvidia-smi se houver). `-` onde não há leitura. |
| `scripts/termica-tendencia.py` (timers `termica-coletar`, `termica-relatorio`) | Registra cada sessão da CI em CSV e gera o relatório de tendência. |
| `monitor-de-uso/scripts/saude-auto.py` | Garante que o `ci-termica` está de pé e que as ventoinhas ficam no máximo durante a CI (ver o zelador). |

## Regras do ci-termica (nesta ordem de importância)
1. **Detecção.** Há CI quando existe algum processo cujo nome (`/proc/*/comm`) casa com `KIT_CI_PADRAO` (padrão `Runner.Worker`), de qualquer usuário. Amostra a cada 15 s. Entra no perfil da CI no primeiro job; sai só depois de **3 min seguidos sem nenhum job** (os jobs de um workflow vêm um atrás do outro).
   **Calor sem CI:** fora da CI, 2 amostras seguidas (30 s) acima de `KIT_TERM_CALOR_C` (80 °C) aplicam o mesmo perfil e o mesmo teto dinâmico (log `ENTROU no perfil térmico por calor`): testes locais pesados também esquentam a máquina. Sai depois de 3 min sem calor nem carga (nenhuma amostra acima de 70 °C e, com o teto abaixo de 100, CPU abaixo de 50%); com carga e fria, o teto sobe até 100 e então sai, sem vaivém. Job que aparece nesse perfil vira CI normal.
2. **Perfil da CI**, nesta ordem: `powerprofilesctl set performance`; `intel_pstate/no_turbo=0` (turbo ligado); `intel_pstate/max_perf_pct=KIT_TERM_TETO_INICIAL` (60); `255` em cada arquivo de ventoinha de `KIT_FAN_BOOST`. Cada valor é lido de volta depois de gravar: o lido é o "aplicado".
3. **Teto dinâmico** (só no modo CI): a cada 60 s, média da temperatura do pacote da CPU nas amostras do minuto.
   - Média **acima de `KIT_TERM_DESCE_C` (80 °C)**: baixa o teto em 10 pontos, até o piso de 50.
   - Média **acima de `KIT_TERM_CRITICO_C` (90 °C)**: volta direto ao teto inicial, sem passar por degraus.
   - **Subida:** máxima do minuto até `KIT_TERM_SOBE_C` (70 °C) por 3 janelas seguidas **e** uso médio da CPU de pelo menos 50% (`/proc/stat`): sobe 10 pontos, até 100. Minuto frio com a CPU ociosa não conta nem zera (senão o teto sobe nas pausas e a carga seguinte bate 95-100 °C).
   - Entre 70 e 80 °C: fica onde está (estabilizou).
4. **Cascata de perfis.** No piso (50%) e ainda acima do limite: desce um degrau de perfil e recomeça o teto em 100: `performance` -> `balanced` -> `power-saver`. No piso do `power-saver`, fica e registra um aviso. Com teto 100 num perfil de baixo e a máquina fria, volta ao perfil anterior com o teto no piso.
5. **Ventoinhas sempre no máximo durante a CI**, em qualquer perfil: a cada amostra, um arquivo de ventoinha abaixo do valor da CI volta a 255 (a troca de perfil pode zerá-lo), inclusive se alguém mudou à mão. `KIT_FAN_BOOST` vazio = não mexe em ventoinha.
6. **Saída repõe o estado de antes** (guardado na entrada em `$KIT_CACHE/ci-termica/estado.json`). Item que alguém **mudou à mão** durante a CI (valor atual diferente do aplicado) **não é reposto**: o dono manda. Teto e perfil mudados pelo próprio ajuste dinâmico contam como "aplicado". Se a CI já rodava na partida e o valor atual já é o da CI, o "antes" usa a reserva: `balanced`, `no_turbo 0`, `max_perf_pct 100`, ventoinha 0.
7. **Robustez.** SIGTERM e SIGINT no modo CI repõem antes de sair (parar o serviço não prende a máquina). Queda no meio da CI (SIGKILL, boot): o estado salvo é retomado na partida seguinte; se o boot mudou e há job, o perfil é reaplicado. Boot novo fora da CI: assim que o `powerprofilesctl` responde, volta ao `balanced`, uma vez por boot. Item ausente ou não gravável vira AVISO no log e o resto segue. O número do `hwmon` muda a cada boot: ventoinhas são achadas por glob e identificadas por `<name do hwmon>/<arquivo>`.
8. **Registro.** Cada troca vai em `$KIT_CACHE/ci-termica/ci-termica.log` e, com o comando de desfazer, em `$KIT_REGISTRO`.
9. O núcleo é Python (stdlib): o bash do Ubuntu 24.04 pode corromper o analisador quando um `trap` roda no meio de `$(...)`, e o SIGTERM no meio da CI precisa repor sempre.

Comandos: `ci-termica.sh --estado` (só lê), `--autoteste` (sysfs falso, não toca o sistema). Desligar tudo: `KIT_TERM_ATIVA=0` no `kit.conf` e `systemctl --user disable --now ci-termica`.

## Variáveis do kit.conf
`KIT_TERM_ATIVA` (1), `KIT_CI_PADRAO` (Runner.Worker), `KIT_TERM_TETO_INICIAL` (60), `KIT_TERM_CALOR_C` (80), `KIT_TERM_SOBE_C` (70), `KIT_TERM_DESCE_C` (80), `KIT_TERM_CRITICO_C` (90), `KIT_FAN_BOOST` (vazio; glob, ex. `/sys/class/hwmon/hwmon*/fan*_boost`), `KIT_TERM_WINDOWS` (0), `KIT_CI_REPO` (opcional, `dono/repositorio`, para a tabela de jobs do relatório), `KIT_CI_CGROUP` (opcional, cgroup dos executores para medir núcleos da CI no `saude.log`).

## Como montar do zero ou adaptar
1. Veja o que a máquina oferece: `ls /sys/devices/system/cpu/intel_pstate/` (Intel com `intel_pstate`), `powerprofilesctl get`, `grep -l . /sys/class/hwmon/*/name` e `bash scripts/temperatura.sh`.
2. **Outro processador.** AMD sem `intel_pstate`: use `cpufreq` (`/sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq`) como teto, em kHz proporcional (100% = `cpuinfo_max_freq`); troque o item `max_perf_pct` por esse e mantenha a lógica de janelas. Sem controle de teto nenhum: fique só com o perfil e registre.
3. **Ventoinhas.** Cada fabricante expõe de um jeito (`fan*_boost` em alguns notebooks gamer com módulo WMI do fabricante, `pwm*` em outros). Procure o arquivo que força a velocidade máxima, defina o glob em `KIT_FAN_BOOST` e, se o valor máximo não for 255, ajuste `CI_TERMICA_CI_BOOST`/`CI_TERMICA_RES_BOOST`. Computador de mesa: deixe vazio.
4. **Permissões** (para o serviço do usuário gravar sem sudo). Exemplo de regra udev que dá a um grupo dedicado (`kit-termica`, crie com `groupadd` e ponha só o seu usuário; evite grupos amplos como `plugdev`) escrita nos arquivos (adapte e crie o arquivo com `sudo`; o gerente pede ao dono via terminal com sudo):
   ```
   # /etc/udev/rules.d/90-ci-termica.rules
   SUBSYSTEM=="hwmon", ATTR{name}=="SEU_MODULO", RUN+="/bin/sh -c 'chgrp kit-termica /sys%p/fan*_boost; chmod 0664 /sys%p/fan*_boost'"
   ```
   e um `tmpfiles.d` para o `intel_pstate` (recriado a cada boot):
   ```
   # /etc/tmpfiles.d/ci-termica.conf
   z /sys/devices/system/cpu/intel_pstate/no_turbo      0664 root plugdev -
   z /sys/devices/system/cpu/intel_pstate/max_perf_pct  0664 root plugdev -
   ```
   O `powerprofilesctl` funciona pelo polkit com a sessão gráfica ativa; sem login depois do boot, o serviço avisa e segue com o resto.
5. Teste com `--autoteste`, ligue o serviço (`systemctl --user enable --now ci-termica`) e acompanhe uma CI real pelo log. Ajuste os limiares no `kit.conf`, não no script.

## Relatórios de tendência (opcional)
`termica-coletar.timer` (diário) acrescenta uma linha por sessão da CI em `tendencia-sessoes.csv` (perfil e teto inicial/final, teto médio ponderado pelo tempo, reduções, subidas, degraus de perfil, temperatura média/p95/máxima, frequência da CPU, carga) e, com `KIT_CI_REPO` e o `gh` autenticado, uma linha por job em `tendencia-jobs.csv`. `termica-relatorio.timer` (desligado; edite a data para umas 4 semanas depois do início) roda `--coletar --relatorio`, grava `relatorios/termica-<data>.txt` e escala `RELATÓRIO TÉRMICO` ao zelador, que avisa o gerente. Alerta quando o teto médio cai 3 pontos por semana ou a temperatura média sobe 1,5 °C por semana, ou um job fica 5% mais lento por semana. Sugestão padrão: limpar as saídas de ar e, se persistir, trocar a pasta térmica.

## Escalações ligadas a esta skill (do `saude-auto`)
`CI-TÉRMICA FORA` (serviço parado mesmo depois de reiniciar), `VENTOINHAS: ... falhou` (escrita de 255 falhou), `VENTOINHAS ZERADAS` (3 reposições em 30 min: algo as zera), `TEMPERATURA CRÍTICA` (CPU >= 96 °C por 1 h com a GPU abaixo de 30 W, ou seja, calor só da CI), `RELATÓRIO TÉRMICO`. Quem investiga é o gerente; o zelador só repassa.

## Windows (WSL2)
A maioria dos usuários roda o kit no Ubuntu dentro do WSL2. O script detecta (`grep -qi microsoft /proc/version`).
- **Não funciona:** `intel_pstate`, `hwmon`, ventoinhas, `powerprofilesctl` e temperatura da CPU do host. O `ci-termica` não dá erro nem fica em laço: registra uma nota ("WSL sem KIT_TERM_WINDOWS=1") e só anota as sessões da CI. `temperatura.sh` imprime `-` na temperatura. O `saude-auto` pula ventoinhas e não cobra o `ci-termica` se não houver systemd (`wsl.conf` com `systemd=true`) nem docker.
- **Funciona:** detecção da CI, registro de sessões, limpeza de disco e escalação de carga (o `df /` do WSL vale), tudo do `saude-auto`.
- **Modo Windows (opcional, `KIT_TERM_WINDOWS=1`):** limita a CPU pelo host via `powercfg.exe` (interop do WSL), no esquema de energia atual: `powercfg.exe /setacvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX N` (corrente) e `/setdcvalueindex` (bateria), seguidos de `powercfg.exe /setactive SCHEME_CURRENT`. Antes de gravar, lê o valor atual (`/query SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX`: os dois últimos `0x...` da saída são corrente e bateria, em qualquer idioma) e o repõe na saída; valor mudado à mão fica. **Sem temperatura no host, o teto fica fixo em `KIT_TERM_TETO_INICIAL` durante a CI** (sem subir nem descer) e volta ao valor de antes na saída. Ligue com `KIT_TERM_WINDOWS=1` no `kit.conf` e reinicie o serviço. Se o `powercfg.exe` não responder (interop desligado), o serviço avisa e segue.
