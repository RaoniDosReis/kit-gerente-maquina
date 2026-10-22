# Aprendizados: vigias por mudança de estado (esperar-*.sh)

- Prova de vigia: prazos em segundos e dados falsos, nunca o relógio e o df reais.
- Script em uso por um vigia: troque por arquivo novo (`mv`), nunca reescreva no lugar.

## Prova de vigia: prazos em segundos e dados falsos, nunca o relógio e o df reais
- Sintoma: provar um reaviso de 30 min ou uma carência de 15 min com variáveis em minutos leva minutos por cenário; e um valor real (disco, temperatura) pode cruzar o limite no meio da prova e passar por "problema novo".
- Regra: dê ao vigia variáveis `*_S` (segundos, com precedência sobre `*_MIN`) e uma variável que fixa a medida física; rode-o como filho, com intervalo de 0,2 s.
- Prova: o autoteste do vigia roda os cenários em segundos; apontado para a versão antiga, falha.

## Script em uso por um vigia: troque por arquivo novo (`mv`), nunca reescreva no lugar
- Sintoma: risco de o bash de um vigia em execução ler código novo pela metade (ele lê o script aos poucos, pelo deslocamento no arquivo).
- Regra: grave a versão nova num temporário da mesma pasta, `chmod`, e `mv -f` por cima: o inode muda, e quem roda segue com o arquivo antigo até sair. Não mate os vigias de outra sessão.
- Prova: `ls -i` antes e depois da troca mostra inodes diferentes.
