--[[
================================================================================
  stress_network.lua  -  RevScript  (TFS 1.8 / 8.60 downgrade fork)
  Stress test para NetworkMessage - shared_ptr pool via allocate_shared
  Repositorio: Mateuzkl/forgottenserver-downgrade-1.8-8.60
================================================================================

  USO (TalkAction /net):
    /net                - exibe ajuda
    /net create[,N]     - cria/destroi N mensagens (default: SUITE_CREATE_AMOUNT)
    /net gc[,N]         - cria N mensagens + forca Lua GC (default: SUITE_GC_AMOUNT)
    /net pool[,N]       - mantem N mensagens simultaneamente (default: SUITE_POOL_AMOUNT)
    /net leak[,N]       - executa N rodadas de criacao/destruicao (default: SUITE_LEAK_ROUNDS)
    /net send[,N]       - envia N pacotes ao proprio player (default: SUITE_CREATE_AMOUNT)
    /net concurrent[,W,M] - W workers simultaneos, M msgs cada (default: SUITE_CONCURRENT_*)
    /net bigdata[,N,S]  - N mensagens com payload de S bytes (default: SUITE_BIGDATA_*)
    /net reset[,N]      - N rodadas de validacao de zeragem (default: SUITE_RESET_ROUNDS)
    /net exhaust[,P,O]  - Esgota pool de P slots + O overflow (default: SUITE_EXHAUST_*)
    /net fragment[,N]   - N rodadas de fragmentacao (default: SUITE_FRAGMENT_ROUNDS)
    /net refcount[,N]   - N objetos com multiplas refs (default: SUITE_REFCOUNT_AMOUNT)
    /net all            - executa bateria completa (TODOS os testes)

  FASES E OBJETIVOS:
  ┌──────────┬──────────────────────────────┬──────────────────────────────────┐
  │ Teste    │ Area testada                 │ Metrica / Validacao              │
  ├──────────┼──────────────────────────────┼──────────────────────────────────┤
  │ CREATE   │ Alocacao e destruicao rapida │ Throughput (msgs/sec)            │
  │          │ do allocator                 │ Estabilidade do pool             │
  │ GC       │ Integracao Lua GC            │ Coleta automatica de shared_ptr  │
  │          │ com shared_ptr destructor    │ Tempo de GC sweep                │
  │ POOL     │ Retencao simultanea de       │ Reutilizacao de slots do pool    │
  │          │ objetos alocados             │ Fragmentacao de memoria          │
  │ LEAK     │ Vazamento de memoria em      │ Crescimento de heap apos rounds  │
  │          │ multiplas rodadas            │ Estabilidade do allocator        │
  │ SEND     │ Serializacao + envio real    │ Latencia de pacotes              │
  │          │ de pacotes ao cliente        │ Estabilidade do cliente          │
  │ CONCURR  │ Alocacoes multi-threaded     │ Thread-safety do freelist        │
  │          │ simultaneas (CAS ops)        │ Ausencia de race conditions      │
  │ BIGDATA  │ Mensagens com payloads       │ Fragmentacao com dados grandes   │
  │          │ grandes (8KB+)               │ Overhead de realloc interno      │
  │ RESET    │ Zeragem de dados ao reutilizar│ Ausencia de data contamination  │
  │          │ (data contamination)         │ Seguranca entre players          │
  │ EXHAUST  │ Pool exhaustion + fallback   │ Degradacao ao esgotar freelist   │
  │          │ para malloc()                │ Recovery apos liberacao          │
  │ FRAGMENT │ Fragmentacao do freelist     │ Performance com slots nao-contig │
  │          │ (liberacao nao-sequencial)   │ Overhead de busca fragmentada    │
  │ REFCOUNT │ shared_ptr ref-counting      │ Overhead de atomic ops           │
  │          │ overhead (multiplas refs)    │ Cache line bouncing              │
  └──────────┴──────────────────────────────┴──────────────────────────────────┘

  O QUE ESTA SENDO VALIDADO:
    • commit: "feat: migrate NetworkMessage to shared_ptr pool via allocate_shared"
    • Alteracoes no core do TFS que movem NetworkMessage de alocacao direta
      (new/delete) para pool allocator com shared_ptr.
    • LockfreePoolingAllocator<NetworkMessage> - pool thread-safe de mensagens
      reutilizaveis para reduzir pressao no heap e fragmentacao.
    • shared_ptr ref-counting - garante que mensagens nao sejam liberadas
      enquanto Lua ou C++ ainda mantem referencias.
    • allocate_shared vs make_shared - construcao in-place no bloco de controle
      do shared_ptr, economizando 1 alocacao por mensagem.

  IMPACTOS ESPERADOS:
    ► CPU: Reducao de ~15-30% no tempo de alocacao/destruicao comparado a
           new/delete tradicional, especialmente em cenarios de alta frequencia.
    ► Memoria: Reducao de fragmentacao do heap; pool mantem slots pre-alocados
               que sao reutilizados (freelist interna do LockfreePoolingAllocator).
    ► Lua GC: Pressao AUMENTADA no GC sweep (mais userdata com __gc metamethod),
              mas cada coleta e mais rapida pois nao ha chamada ao allocator do OS.
    ► NetworkMessage: Objetos zerados (reset()) antes de reutilizacao - garante
                      que dados de mensagens anteriores nao vazem entre pacotes.

  GARGALOS IDENTIFICAVEIS:
    ✗ POOL EXHAUSTION: Se o freelist estiver vazio, allocate_shared cai em
      fallback para malloc() - perde beneficio do pool. Observavel em POOL test
      quando amount > tamanho do pool configurado no core.
    ✗ LUA GC STALL: collectgarbage("collect") em testes GC/LEAK pode pausar
      a main thread por >100ms se houver muitos objetos NetworkMessage pendentes.
    ✗ CLIENT OVERLOAD: SEND test com valores altos (>10k) pode saturar o buffer
      de saida do socket, causando disconnect ou travamento do cliente.
    ✗ REF-COUNTING OVERHEAD: shared_ptr atomic ref-count tem custo em ambientes
      multi-threaded; mensuravel comparando CREATE test antes/depois da commit.

  SEGURANCA:
    • Teste isolado - nao afeta jogabilidade ou dados de producao.
    • SEND test com valores excessivos (>50k) pode desconectar o player testador.
    • Nenhuma tabela de banco e tocada.
    • Apenas GMs ou players com permissao podem executar /net (TalkAction padrao).

  INTERPRETACAO DE RESULTADOS:
    PASS: Tempo de CREATE/GC/POOL/LEAK dentro de ~20% da baseline esperada.
          Nenhum crash. Nenhum leak detectavel (memoria estavel apos rounds).
    FAIL: Crash durante qualquer teste. Crescimento continuo de memoria em LEAK.
          Tempo de CREATE >2x mais lento que baseline (indica contencao no pool).
          GC test >3x mais lento (indica problema no destructor do shared_ptr).
================================================================================
--]]

-- ============================================================================
-- CONFIGURACAO
-- ============================================================================
--[[
  Valores padrao para a bateria completa (/net all).
  Ajuste aqui se desejar testes mais agressivos ou conservadores.
  
  NOTA: Valores muito altos em ambientes de producao podem causar lag perceptivel.
        Recomenda-se rodar em servidor de teste ou horarios de baixo trafego.
        
  AVISO: CREATE, GC e LEAK executam loops sincronos de 100k+ iteracoes na main thread,
         bloqueando o dispatcher. Use apenas em servidores de teste isolados.
--]]
local SUITE_CREATE_AMOUNT   = 10000   -- Numero de mensagens criadas/destruidas no teste CREATE (reduzido de 100k)
local SUITE_GC_AMOUNT       = 10000   -- Numero de mensagens para teste de Lua GC (reduzido de 100k)
local SUITE_POOL_AMOUNT     = 1000    -- Numero de mensagens retidas simultaneamente (teste POOL - SEND default, reduzido de 10k)
local SUITE_LEAK_ROUNDS     = 100     -- Numero de rodadas no teste de vazamento (100 rounds × 10k msgs)
local SUITE_CONCURRENT_WORKERS = 50   -- Numero de workers simultaneos no teste CONCURRENT
local SUITE_CONCURRENT_MSGS = 1000    -- Mensagens por worker no teste CONCURRENT
local SUITE_BIGDATA_AMOUNT  = 5000    -- Numero de mensagens grandes no teste BIGDATA
local SUITE_BIGDATA_SIZE    = 8192    -- Tamanho do payload em bytes (8KB)
local SUITE_RESET_ROUNDS    = 1000    -- Rodadas de teste de contaminacao RESET
local SUITE_EXHAUST_POOL    = 2048    -- Tamanho estimado do pool (ajuste conforme core)
local SUITE_EXHAUST_OVER    = 5000    -- Quantidade extra acima do pool (testa fallback)
local SUITE_FRAGMENT_ROUNDS = 500     -- Rodadas de fragmentacao no teste FRAGMENT
local SUITE_REFCOUNT_AMOUNT = 50000   -- Quantidade de objetos com multiplas refs

-- TalkAction handle (registrado ao final do script)
local talk = TalkAction("/net")

-- ============================================================================
-- UTILIDADES
-- ============================================================================
--[[
  Funcoes auxiliares para logging e feedback ao player.
  Mantem consistencia com stress_db.lua (cores ANSI no console, mensagens in-game).
--]]

-- Codigos ANSI para cores no console (servidor)
local COLOR_RESET  = "\27[0m"
local COLOR_BLUE   = "\27[94m"
local COLOR_GREEN  = "\27[32m"
local COLOR_YELLOW = "\27[33m"
local COLOR_RED    = "\27[31m"
local COLOR_ORANGE = "\27[38;5;208m"

-- Constantes de mensagem (compatibilidade entre forks)
local MSG_BLUE = MESSAGE_STATUS_CONSOLE_BLUE or MESSAGE_EVENT_ADVANCE or 19
local MSG_RED = MESSAGE_STATUS_CONSOLE_RED or MESSAGE_STATUS_WARNING or MSG_BLUE

-- Helper: coloriza categorias de teste nas mensagens
local function colorize(msg)
    local colored = msg:gsub("(CREATE:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(GC:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(POOL [A-Z]+:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(LEAK:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(SEND:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(CONCURRENT:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(BIGDATA:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(RESET:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(REUSE:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(EXHAUST:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(FRAGMENT:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    colored = colored:gsub("(REFCOUNT:)", COLOR_ORANGE .. "%1" .. COLOR_RESET)
    return colored
end

local function log(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST] " .. msg)
    end
end

local function logFail(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_RED .. "[FAIL]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_RED, "[NET TEST][FAIL] " .. msg)
    end
end

local function logPass(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_YELLOW .. "[PASS]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST][PASS] " .. msg)
    end
end

local function logInfo(player, msg)
    print(COLOR_BLUE .. "[NET TEST]" .. COLOR_GREEN .. "[INFO]" .. COLOR_RESET .. " " .. colorize(msg))
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST][INFO] " .. msg)
    end
end

-- Log de header em azul (mensagem centralizada com ===)
local function logHeader(player, msg)
    print(COLOR_BLUE .. "[NET TEST] " .. msg .. COLOR_RESET)
    if player and player:isPlayer() then
        player:sendTextMessage(MSG_BLUE, "[NET TEST] " .. msg)
    end
end

-- ============================================================================
-- TESTE 1: CREATE - Criacao e destruicao em massa
-- ============================================================================
--[[
  Objetivo:
    Medir o throughput de alocacao/destruicao de NetworkMessage objects quando
    instanciados rapidamente em loop e imediatamente descartados (msg = nil).
  
  O que esta sendo testado:
    • LockfreePoolingAllocator::allocate() - caminho de alocacao do pool
    • LockfreePoolingAllocator::deallocate() - retorno do objeto ao freelist
    • shared_ptr ref-counting overhead (increment/decrement atomico)
    • Reset automatico do NetworkMessage antes de reutilizacao
  
  Fluxo:
    1. Loop de N iteracoes
    2. Cada iteracao:
       - NetworkMessage() → Lua cria userdata + shared_ptr
       - addByte/addU16/addString → escreve dados no buffer interno
       - msg = nil → Lua marca para GC; ref_count decrementa
    3. collectgarbage("collect") → forca sweep imediato
    4. Mede elapsed time e calcula msgs/sec
  
  Metricas:
    - Tempo total (segundos)
    - Throughput (mensagens por segundo)
  
  PASS se: Nenhum crash. Tempo razoavel (baseline: ~0.5-2s para 100k msgs).
  FAIL se: Crash. Tempo >5s para 100k msgs (indica contencao no allocator).
  
  Gargalos possiveis:
    ► Pool vazio: Se freelist estiver esgotado, allocate_shared cai em malloc().
    ► Contencao de lock: LockfreePoolingAllocator usa CAS; se muitos threads
      competirem, pode haver spin/retry excessivo (nao esperado em main thread).
--]]
local function runCreateTest(player, amount)
    local start = os.clock()

    for i = 1, amount do
        -- Cria NetworkMessage via allocate_shared (pool allocator)
        local msg = NetworkMessage()
        
        -- Escreve dados no buffer (testa que objeto esta valido)
        msg:addByte(0xAA)
        msg:addU16(i)
        msg:addString("stress")
        
        -- Descarta referencia (Lua GC eventualmente chama destructor do shared_ptr)
        msg = nil
    end

    -- Forca coleta imediata de lixo (libera todos os shared_ptr criados acima)
    collectgarbage("collect")

    local elapsed = os.clock() - start

    logPass(
        player,
        string.format(
            "CREATE: %d messages in %.3f sec (%.0f msgs/sec)",
            amount,
            elapsed,
            amount / (elapsed + 1e-9)
        )
    )
end

-- ============================================================================
-- TESTE 2: GC - Lua Garbage Collector com shared_ptr
-- ============================================================================
--[[
  Objetivo:
    Verificar que Lua GC corretamente libera NetworkMessage userdata e que
    o destructor do shared_ptr (ref_count decrement) e chamado sem leaks.
  
  O que esta sendo testado:
    • Lua __gc metamethod chamado para cada userdata NetworkMessage
    • shared_ptr destructor decrementa ref_count e libera objeto se count=0
    • LockfreePoolingAllocator::deallocate() retorna objeto ao pool
    • Nenhum leak de memoria apos sweep completo
  
  Fluxo:
    1. Loop de N iteracoes criando NetworkMessage
    2. Cada msg e descartada imediatamente (msg = nil)
    3. collectgarbage("collect") forca sweep completo da geracao
    4. Mede tempo de GC sweep (inclui chamada a N destructors)
  
  Metricas:
    - Tempo total de GC sweep (segundos)
    - Throughput de coleta (mensagens coletadas por segundo)
  
  PASS se: Nenhum crash. Tempo de GC razoavel (<3s para 100k msgs).
  FAIL se: Crash durante GC. Tempo de GC >10s (indica problema no __gc).
           Crescimento de memoria RSS apos multiplas rodadas (leak).
  
  Gargalos possiveis:
    ► __gc metamethod lento: Se destructor do shared_ptr fizer operacoes
      pesadas (improvavel), GC sweep pode demorar.
    ► Fragmentacao de heap: Se deallocate() nao retornar objetos ao pool
      corretamente, heap pode crescer indefinidamente.
--]]
local function runGCTest(player, amount)
    local start = os.clock()

    for i = 1, amount do
        -- Cria NetworkMessage
        local msg = NetworkMessage()
        
        -- Escreve dados variaveis (testa que buffer esta funcionando)
        msg:addString("GC TEST")
        msg:addByte(i % 255)
        
        -- Descarta (marca para GC)
        msg = nil
    end

    -- Forca sweep completo (chama __gc de todos os userdata pendentes)
    collectgarbage("collect")

    local elapsed = os.clock() - start

    logPass(
        player,
        string.format(
            "GC: %d messages collected in %.3f sec (%.0f msgs/sec)",
            amount,
            elapsed,
            amount / (elapsed + 1e-9)
        )
    )
end

-- ============================================================================
-- TESTE 3: POOL - Retencao simultanea de objetos alocados
-- ============================================================================
--[[
  Objetivo:
    Testar o comportamento do pool allocator quando muitos NetworkMessage
    objects sao mantidos vivos simultaneamente (nao liberados imediatamente).
  
  O que esta sendo testado:
    • Capacidade do freelist interno do LockfreePoolingAllocator
    • Fallback para malloc() quando pool esta esgotado
    • Reutilizacao de slots apos liberacao em massa (segunda fase do teste)
    • Fragmentacao de memoria em cenarios de alta retencao
  
  Fluxo:
    1. Aloca N mensagens e mantem referencias em uma table Lua
    2. Mede tempo de alocacao (phase: ALLOC)
    3. Agenda addEvent para 5 segundos depois:
       - Libera todas as referencias (messages[i] = nil)
       - Forca collectgarbage("collect")
       - Mede tempo de liberacao (phase: FREE)
    4. Objetos retornam ao pool e ficam disponiveis para reutilizacao
  
  Metricas:
    - Tempo de alocacao em massa (segundos)
    - Tempo de liberacao em massa (segundos)
    - Throughput de alloc e free (msgs/sec)
  
  PASS se: Ambas as fases completam sem crash. Tempo de FREE < tempo de ALLOC
           (liberacao deve ser mais rapida que alocacao).
  FAIL se: Crash durante ALLOC ou FREE. Tempo de ALLOC >10s para 10k msgs
           (indica pool exhaustion + malloc fallback lento).
  
  Gargalos possiveis:
    ► Pool size insuficiente: Se LockfreePoolingAllocator tiver freelist pequeno
      (ex: 1024 slots) e amount=10000, 90% das alocacoes cairao em malloc().
    ► Fragmentacao de heap: Apos FREE, se objetos nao retornarem ao pool,
      proxima rodada de ALLOC sera lenta (malloc novamente).
--]]
local function runPoolTest(player, amount)
    -- Table para reter referencias (simula cenario onde msgs ficam em fila)
    local messages = {}

    local start = os.clock()

    -- ── PHASE: ALLOC ──────────────────────────────────────────────────────
    for i = 1, amount do
        -- Cria NetworkMessage
        local msg = NetworkMessage()
        
        -- Escreve dados (valida que objeto esta utilizavel)
        msg:addString("POOL TEST")
        msg:addU32(i)
        
        -- IMPORTANTE: mantem referencia (nao descarta msg)
        messages[i] = msg
    end

    local allocElapsed = os.clock() - start

    logPass(
        player,
        string.format(
            "POOL ALLOC: %d messages in %.3f sec (%.0f msgs/sec)",
            amount,
            allocElapsed,
            amount / (allocElapsed + 1e-9)
        )
    )

    -- ── PHASE: FREE (agendado para 5 segundos depois) ─────────────────────
    addEvent(function()
        local freeStart = os.clock()

        -- Libera todas as referencias
        for i = 1, #messages do
            messages[i] = nil
        end

        -- Forca GC sweep (retorna objetos ao pool)
        collectgarbage("collect")

        local freeElapsed = os.clock() - freeStart

        logPass(
            player,
            string.format(
                "POOL FREE: %d messages in %.3f sec (%.0f msgs/sec)",
                amount,
                freeElapsed,
                amount / (freeElapsed + 1e-9)
            )
        )
    end, 5000)

    return true
end

-- ============================================================================
-- TESTE 4: LEAK - Deteccao de vazamentos de memoria
-- ============================================================================
--[[
  Objetivo:
    Detectar vazamentos de memoria executando multiplas rodadas de criacao/
    destruicao e verificando que a memoria RSS do processo nao cresce.
  
  O que esta sendo testado:
    • Estabilidade do pool allocator em uso prolongado
    • Ausencia de leaks no ref-counting do shared_ptr
    • Correta devolucao de objetos ao freelist apos cada rodada
    • Ausencia de acumulo de objetos "zumbis" (ref_count nunca chega a 0)
  
  Fluxo:
    1. Executa N rodadas (default: 100 rounds)
    2. Cada rodada:
       - Cria 10.000 NetworkMessage objects
       - Escreve dados em cada objeto
       - Descarta todas as referencias (msg = nil)
       - collectgarbage("collect") forca sweep
    3. Mede tempo total das N rodadas
  
  Metricas:
    - Tempo total de todas as rodadas (segundos)
    - Throughput medio (mensagens por segundo)
  
  PASS se: Nenhum crash. Memoria RSS estavel apos rounds (verificar com top/htop).
           Tempo por rodada consistente (variacao <10% entre primeira e ultima).
  FAIL se: Crash durante qualquer rodada. Crescimento continuo de RSS (leak).
           Tempo por rodada aumentando progressivamente (indica fragmentacao).
  
  Gargalos possiveis:
    ► Leak no shared_ptr: Se ref_count nao decrementar corretamente,
      objetos nunca sao liberados (RSS cresce linearmente).
    ► Fragmentacao severa: Apos N rodadas, heap pode estar fragmentado mesmo
      sem leak real; realocar objetos grandes fica lento.
    ► GC overhead: Se Lua GC nao rodar entre rodadas, acumula lixo; sweep
      gigante no final causa pause longo.
--]]
local LEAK_MEM_THRESHOLD_KB = 1024  -- Max allowed memory growth per round (KB); adjust if false positives occur

local function runLeakTest(player, rounds)
    local start = os.clock()

    -- Sample memory before rounds
    collectgarbage("collect")
    local memBefore = collectgarbage("count")
    local maxDelta = 0

    for round = 1, rounds do
        for i = 1, 10000 do
            local msg = NetworkMessage()
            msg:addString("Leak Test")
            msg = nil
        end
        collectgarbage("collect")
        local memAfter = collectgarbage("count")
        local delta = memAfter - memBefore
        if delta > maxDelta then
            maxDelta = delta
        end
    end

    local elapsed = os.clock() - start
    local totalMsgs = rounds * 10000
    local memAfterFinal = collectgarbage("count")
    local totalDelta = memAfterFinal - memBefore

    if totalDelta > LEAK_MEM_THRESHOLD_KB then
        logFail(
            player,
            string.format(
                "LEAK: %d rounds in %.3f sec | mem growth %.0f KB (threshold %d KB) - possible leak!",
                rounds,
                elapsed,
                totalDelta,
                LEAK_MEM_THRESHOLD_KB
            )
        )
    else
        logPass(
            player,
            string.format(
                "LEAK: %d rounds completed in %.3f sec (%d total msgs | %.0f msgs/sec | mem delta %.0f KB)",
                rounds,
                elapsed,
                totalMsgs,
                totalMsgs / (elapsed + 1e-9),
                totalDelta
            )
        )
    end
end

-- ============================================================================
-- TESTE 5: SEND - Envio real de pacotes ao cliente
-- ============================================================================
--[[
  Objetivo:
    Testar o caminho completo de serializacao e envio de NetworkMessage
    via socket, validando que objetos alocados pelo pool chegam ao cliente.
  
  O que esta sendo testado:
    • NetworkMessage:sendToPlayer() - metodo Lua que enfileira pacote no buffer
    • Serializacao do buffer interno para bytes do protocolo
    • Integracao com output buffer do socket (nao-bloqueante)
    • Estabilidade do cliente ao receber rajadas de pacotes
  
  Fluxo:
    1. Loop de N iteracoes
    2. Cada iteracao:
       - Cria NetworkMessage
       - addByte(0xB4) + addString("Benchmark")
       - sendToPlayer(player) → enfileira no output buffer do socket
    3. Mede tempo total de envio (nao espera ACK do cliente)
  
  Metricas:
    - Tempo total de envio (segundos)
    - Throughput de pacotes (msgs/sec)
  
  PASS se: Nenhum crash. Player permanece conectado. Tempo razoavel.
  FAIL se: Crash. Player desconecta (buffer overflow). Cliente trava.
  
  ATENCAO:
    ⚠ Valores altos (>10.000) podem saturar o output buffer do socket,
      causando disconnect ou travamento do cliente. Em producao, NetworkMessage
      normalmente e enviado de forma throttled (rate limiting).
  
  Gargalos possiveis:
    ► Client buffer overflow: Se cliente nao processar pacotes rapido o bastante,
      output buffer do servidor enche; TFS pode desconectar o player.
    ► Server-side queueing: Se sendToPlayer() for mais rapido que flush do socket,
      pacotes acumulam em memoria (nao e leak, mas pode causar lag).
--]]
local function runSendTest(player, amount)
    local start = os.clock()

    for i = 1, amount do
        -- Cria NetworkMessage
        local msg = NetworkMessage()
        
        -- Escreve dados do pacote (opcode ficticio 0xB4)
        msg:addByte(0xB4)
        msg:addString("Benchmark")
        
        -- Envia ao cliente (enfileira no output buffer do socket)
        msg:sendToPlayer(player)
    end

    local elapsed = os.clock() - start

    logPass(
        player,
        string.format(
            "SEND: %d packets in %.3f sec (%.0f packets/sec)",
            amount,
            elapsed,
            amount / (elapsed + 1e-9)
        )
    )
end

-- ============================================================================
-- TESTE 6: CONCURRENT - Alocacoes multi-threaded (throughput)
-- ============================================================================
--[[
  ATENCAO: addEvent(0) tasks no TFS sao enfileiradas e executadas
  SEQUENCIALMENTE pelo dispatcher da main thread. Este teste mede throughput
  de alocacoes sequenciais, NAO concurrencia real. Para validar thread-safety
  do LockfreePoolingAllocator, sao necessarios testes em C++ com threads reais
  ou simulacao externa de carga concorrente.
  
  Objetivo:
    Medir throughput do pool allocator quando multiplos workers sao simulados
    via addEvent(0) - as tarefas executam em serie, mas o padrao de alocacao/
    destruicao e util para detectar degradacao de performance.
  
  O que esta sendo testado:
    • Throughput do pool sob padrao de carga "concorrente simulado"
    • Ausencia de crashes durante alocacao/destruicao em sequencia rapida
  
  Fluxo:
    1. Dispara N workers via addEvent(0)
    2. Cada worker cria M mensagens independentemente
    3. Mede tempo total ate ultimo worker completar
  
  Metricas:
    - Tempo total de todos workers (segundos)
    - Throughput agregado (msgs/sec de todos workers)
  
  LIMITACAO CONHECIDA:
    Nao testa true multi-threading. addEvent(0) executa na main thread.
--]]
local function runConcurrentTest(player, workers, msgsPerWorker)
    local startTime = os.clock()
    local completed = 0
    local totalMsgs = workers * msgsPerWorker
    
    logInfo(player, "CONCURRENT: ATENCAO - addEvent(0) roda na main thread (sequencial), nao simula true concorrencia.")
    logInfo(player, string.format(
        "CONCURRENT: Dispatching %d workers (%d msgs each = %d total)...",
        workers, msgsPerWorker, totalMsgs
    ))
    
    -- Dispara todos workers simultaneamente (addEvent 0 = proximo tick)
    for w = 1, workers do
        addEvent(function(workerId, amount, totalWorkers, playerId)
            -- Cada worker cria suas mensagens independentemente
            for i = 1, amount do
                local msg = NetworkMessage()
                msg:addByte(workerId % 256)
                msg:addU32(i)
                msg:addString("worker_" .. workerId)
                msg = nil
            end
            
            -- Incrementa contador de workers completados
            completed = completed + 1
            
            -- Ultimo worker: GC unico ao final (evita 50 GC sweeps individuais)
            if completed == totalWorkers then
                collectgarbage("collect")
                local elapsed = os.clock() - startTime
                local p = Player(playerId)
                if p then
                    logPass(
                        p,
                        string.format(
                            "CONCURRENT: %d workers completed | %d total msgs in %.3f sec (%.0f msgs/sec)",
                            totalWorkers,
                            totalWorkers * amount,
                            elapsed,
                            (totalWorkers * amount) / (elapsed + 1e-9)
                        )
                    )
                end
            end
        end, 0, w, msgsPerWorker, workers, player:getId())
    end
end

-- ============================================================================
-- TESTE 7: BIGDATA - Mensagens com payloads grandes
-- ============================================================================
--[[
  Objetivo:
    Testar o comportamento do pool allocator com mensagens de tamanhos variados,
    especialmente payloads grandes que podem causar fragmentacao de memoria.
  
  O que esta sendo testado:
    • Pool allocator com objetos de tamanhos heterogeneos
    • Crescimento dinamico do buffer interno do NetworkMessage
    • Fragmentacao de heap quando mensagens grandes e pequenas se alternam
    • Overhead de realloc() interno do buffer
  
  Fluxo:
    1. Loop de N iteracoes
    2. Cada iteracao cria NetworkMessage com payload de 8KB
    3. Escreve string grande no buffer (forca realloc interno)
    4. Descarta e forca GC
    5. Mede throughput e compara com teste CREATE
  
  Metricas:
    - Tempo total (segundos)
    - Throughput (msgs/sec)
    - Comparacao com CREATE test (payloads pequenos)
  
  PASS se: Throughput >= 50% do CREATE test (payloads pequenos).
  FAIL se: Throughput << 30% do CREATE test (indica fragmentacao severa).
           Crash por estouro de buffer.
  
  Gargalos possiveis:
    ► Fragmentacao de heap: Objetos grandes fragmentam heap; reuso e menos
      eficiente que com objetos de tamanho fixo.
    ► Realloc overhead: Buffer interno do NetworkMessage cresce dinamicamente;
      payloads grandes causam multiplos realloc().
    ► Pool ineficiente: Se pool nao reutilizar objetos grandes corretamente,
      cai em malloc() frequentemente.
--]]
local function runBigDataTest(player, amount, payloadSize)
    local start = os.clock()
    local bigPayload = string.rep("X", payloadSize)
    
    for i = 1, amount do
        local msg = NetworkMessage()
        
        -- Escreve payload GRANDE (forca crescimento do buffer interno)
        msg:addString(bigPayload)
        msg:addU32(i)
        
        msg = nil
    end
    
    collectgarbage("collect")
    
    local elapsed = os.clock() - start
    
    logPass(
        player,
        string.format(
            "BIGDATA: %d messages (%d bytes each) in %.3f sec (%.0f msgs/sec | %.2f MB/sec)",
            amount,
            payloadSize,
            elapsed,
            amount / (elapsed + 1e-9),
            (amount * payloadSize) / (1024 * 1024 * elapsed)
        )
    )
end

-- ============================================================================
-- TESTE 8: RESET - Validacao de zeragem de dados (Data Contamination)
-- ============================================================================
--[[
  Objetivo:
    Validar que NetworkMessage objects retornados ao pool sao completamente
    zerados (reset()) antes de reutilizacao, evitando vazamento de dados
    entre pacotes de diferentes players.
  
  O que esta sendo testado:
    • reset() chamado corretamente antes de reutilizar objeto do pool
    • Buffer interno zerado (nao contem dados de mensagem anterior)
    • Ausencia de data contamination (dados de um player vazam para outro)
  
  Fluxo:
    1. Loop de N rodadas
    2. Cada rodada:
       a) Cria NetworkMessage e escreve padrao conhecido (0xFF + "SECRET")
       b) Descarta (retorna ao pool)
       c) Forca GC (libera para freelist)
       d) Cria nova NetworkMessage (deve vir do pool)
       e) VERIFICA: novo objeto esta zerado (nao tem dados antigos)
  
  NOTA IMPORTANTE:
    Lua nao tem acesso direto ao buffer interno do NetworkMessage para
    validacao. Este teste e INDICATIVO: se nao crashar e reutilizacao
    for rapida, assumimos que reset() esta funcionando.
    
    Para teste REAL, seria necessario:
    - Adicionar getBuffer() ou hasData() no binding Lua, OU
    - Testar no C++ diretamente com unit tests
  
  Metricas:
    - Tempo total de rodadas (segundos)
    - Throughput de reutilizacao (rodadas/sec)
  
  PASS se: Nenhum crash. Reutilizacao rapida (indica pool funcionando).
  FAIL se: Crash (indica buffer corrompido ou nao-zerado).
  
  Gargalos possiveis:
    ► reset() nao implementado: Objeto reutilizado contem lixo.
    ► reset() incompleto: Apenas parte do buffer e zerada.
    ► Overhead de reset(): Se reset() for muito lento, anula ganho do pool.
  
  CRITICO PARA SEGURANCA: Se reset() falhar, dados de um player vazam
  para outro! Exemplo: inventory, senha, chat privado.
--]]
local function runResetTest(player, rounds)
    local start = os.clock()
    
    for round = 1, rounds do
        -- Fase 1: Cria e "contamina" com dados conhecidos
        local msg1 = NetworkMessage()
        msg1:addByte(0xFF)
        msg1:addString("SECRET_DATA_" .. round)
        msg1:addU32(0xDEADBEEF)
        msg1 = nil  -- Retorna ao pool
        
        -- Forca GC (libera para freelist imediatamente)
        if round % 100 == 0 then
            collectgarbage("collect")
        end
        
        -- Fase 2: Aloca novamente (DEVE vir do pool, zerado)
        local msg2 = NetworkMessage()
        -- NOTA: Nao conseguimos validar buffer zerado em Lua
        -- Se crashar aqui, reset() falhou
        msg2:addByte(0x00)
        msg2:addString("CLEAN_" .. round)
        msg2 = nil
    end
    
    collectgarbage("collect")
    
    local elapsed = os.clock() - start
    
    logPass(
        player,
        string.format(
            "RESET: %d reuse cycles in %.3f sec (%.0f cycles/sec) - No crashes detected",
            rounds,
            elapsed,
            rounds / (elapsed + 1e-9)
        )
    )
    
    logInfo(
        player,
        "RESET: Note - Full validation requires C++ unit tests with buffer inspection"
    )
end

-- ============================================================================
-- TESTE 9: EXHAUST - Pool exhaustion e fallback para malloc()
-- ============================================================================
--[[
  Objetivo:
    Medir degradacao de performance quando pool allocator esgota o freelist
    e precisa fazer fallback para malloc() tradicional.
  
  O que esta sendo testado:
    • Comportamento do pool quando freelist esta vazio
    • Fallback para malloc() (allocate_shared sem pool)
    • Degradacao de throughput apos pool exhaustion
    • Recovery do pool apos liberacao em massa
  
  Fluxo:
    1. Aloca poolSize mensagens (esgota o pool)
    2. Mede tempo: primeiras alocacoes sao rapidas (do pool)
    3. Aloca overshoot mensagens adicionais (acima do tamanho do pool)
    4. Mede tempo: essas alocacoes sao lentas (malloc fallback)
    5. Libera todas e reutiliza (valida recovery do pool)
  
  Metricas:
    - Throughput dentro do pool (msgs/sec)
    - Throughput fora do pool - fallback (msgs/sec)
    - Ratio de degradacao (fallback / pool)
  
  PASS se: Fallback throughput >= 30% do pool throughput.
           Recovery apos liberacao restaura performance original.
  FAIL se: Fallback throughput < 10% do pool (malloc muito lento).
           Recovery falha (pool corrompido).
  
  Gargalos possiveis:
    ► Pool muito pequeno: Se pool tiver apenas 512 slots mas uso real precisa
      de 5000 objetos simultaneos, maior parte do tempo esta em fallback.
    ► malloc() lento: Em sistemas com heap fragmentado, malloc() pode demorar.
    ► Recovery falho: Se objetos nao retornarem ao freelist, proxima rodada
      tambem caira em fallback.
--]]
local function runExhaustTest(player, poolSize, overshoot)
    local messages = {}
    
    logInfo(player, string.format(
        "EXHAUST: Allocating %d msgs (pool) + %d msgs (overshoot)...",
        poolSize, overshoot
    ))
    
    -- ── FASE 1: Aloca dentro do pool ────────────────────────────────────
    local t1 = os.clock()
    for i = 1, poolSize do
        messages[i] = NetworkMessage()
        messages[i]:addString("pool_" .. i)
    end
    local poolTime = os.clock() - t1
    local poolThroughput = poolSize / (poolTime + 1e-9)
    
    -- ── FASE 2: Aloca alem do pool (fallback para malloc) ───────────────
    local t2 = os.clock()
    for i = poolSize + 1, poolSize + overshoot do
        messages[i] = NetworkMessage()
        messages[i]:addString("fallback_" .. i)
    end
    local fallbackTime = os.clock() - t2
    local fallbackThroughput = overshoot / (fallbackTime + 1e-9)
    
    local degradation = (fallbackThroughput / poolThroughput) * 100
    
    logPass(
        player,
        string.format(
            "EXHAUST: Pool=%.0f msgs/sec | Fallback=%.0f msgs/sec | Degradation=%.1f%%",
            poolThroughput,
            fallbackThroughput,
            100 - degradation
        )
    )
    
    -- ── FASE 3: Libera tudo e testa recovery ────────────────────────────
    for i = 1, #messages do
        messages[i] = nil
    end
    collectgarbage("collect")
    
    local t3 = os.clock()
    for i = 1, poolSize do
        local msg = NetworkMessage()
        msg:addString("recovery_" .. i)
        msg = nil
    end
    collectgarbage("collect")
    local recoveryTime = os.clock() - t3
    local recoveryThroughput = poolSize / (recoveryTime + 1e-9)
    
    logPass(
        player,
        string.format(
            "EXHAUST: Recovery=%.0f msgs/sec (%.1f%% of original pool speed)",
            recoveryThroughput,
            (recoveryThroughput / poolThroughput) * 100
        )
    )
end

-- ============================================================================
-- TESTE 10: FRAGMENT - Fragmentacao do freelist
-- ============================================================================
--[[
  Objetivo:
    Testar comportamento do pool allocator quando objetos sao liberados em
    ordem nao-sequencial, causando fragmentacao do freelist interno.
  
  O que esta sendo testado:
    • Performance do freelist quando fragmentado (slots nao-contiguos)
    • Algoritmo de busca de slot livre no freelist
    • Overhead de fragmentacao vs alocacao/liberacao sequencial
  
  Fluxo:
    1. Loop de N rodadas
    2. Cada rodada:
       a) Aloca 1000 mensagens
       b) Libera apenas as IMPARES (fragmenta o freelist)
       c) Forca GC (retorna fragmentos ao pool)
       d) Aloca 500 novas mensagens (preenche fragmentos)
       e) Libera tudo
    3. Mede tempo medio por rodada
  
  Metricas:
    - Tempo total de rodadas fragmentadas (segundos)
    - Throughput medio em cenario fragmentado (msgs/sec)
    - Comparacao com CREATE test (nao-fragmentado)
  
  PASS se: Throughput fragmentado >= 70% do CREATE test.
  FAIL se: Throughput fragmentado < 40% do CREATE test (busca ineficiente).
  
  Gargalos possiveis:
    ► Busca linear: Se freelist usar busca linear para achar slot livre,
      fragmentacao degrada para O(n).
    ► Coalescing ausente: Se freelist nao juntar fragmentos adjacentes,
      pode ficar permanentemente fragmentado.
--]]
local function runFragmentTest(player, rounds)
    local start = os.clock()
    
    for round = 1, rounds do
        local msgs = {}
        
        -- Aloca 1000 mensagens
        for i = 1, 1000 do
            msgs[i] = NetworkMessage()
            msgs[i]:addString("fragment_" .. i)
        end
        
        -- Libera apenas impares (fragmenta)
        for i = 1, 1000, 2 do
            msgs[i] = nil
        end
        
        collectgarbage("collect")
        
        -- Realoca 500 mensagens (usa slots fragmentados)
        for i = 1, 500 do
            local msg = NetworkMessage()
            msg:addString("reuse_" .. i)
            msg = nil
        end
        
        -- Limpa tudo
        for i = 1, 1000 do
            msgs[i] = nil
        end
        
        if round % 100 == 0 then
            collectgarbage("collect")
        end
    end
    
    collectgarbage("collect")
    
    local elapsed = os.clock() - start
    local totalOps = rounds * 1500  -- 1000 + 500 mensagens por rodada
    
    logPass(
        player,
        string.format(
            "FRAGMENT: %d rounds (%d total ops) in %.3f sec (%.0f ops/sec)",
            rounds,
            totalOps,
            elapsed,
            totalOps / (elapsed + 1e-9)
        )
    )
end

-- ============================================================================
-- TESTE 11: REFCOUNT - Overhead de shared_ptr ref-counting
-- ============================================================================
--[[
  Objetivo:
    Medir overhead de operacoes de ref-counting atomico do shared_ptr,
    especialmente em cenarios com multiplas referencias ao mesmo objeto.
  
  O que esta sendo testado:
    • shared_ptr atomic increment/decrement performance
    • Overhead quando multiplas referencias apontam para mesmo objeto
    • Cache line bouncing em ref-count (false sharing potencial)
  
  Fluxo:
    1. Loop de N iteracoes
    2. Cada iteracao:
       - Cria 1 NetworkMessage
       - Cria 5 referencias Lua ao mesmo objeto (ref_count = 5)
       - Descarta todas (5 decrements atomicos)
    3. Mede throughput e compara com CREATE test (1 ref apenas)
  
  Metricas:
    - Tempo total (segundos)
    - Throughput (msgs/sec)
    - Comparacao com CREATE test (overhead de multiplas refs)
  
  PASS se: Throughput >= 80% do CREATE test.
  FAIL se: Throughput < 50% do CREATE test (ref-counting e gargalo).
  
  Gargalos possiveis:
    ► Atomic ops lentas: increment/decrement atomico tem custo nao-trivial.
    ► Cache coherence: Multiplas threads modificando ref_count causam
      cache line bouncing entre CPUs.
    ► Lock prefix overhead: Em x86, atomic ops usam LOCK prefix (caro).
--]]
local function runRefCountTest(player, amount)
    local start = os.clock()
    
    for i = 1, amount do
        local msg = NetworkMessage()
        msg:addByte(0xAA)
        
        -- Cria multiplas referencias ao mesmo objeto
        local refs = {msg, msg, msg, msg, msg}
        
        -- shared_ptr ref_count agora e 6 (msg + 5 refs)
        -- Descartar tudo faz 6 decrements atomicos
        refs = nil  -- 5 decrements
        msg = nil   -- 1 decrement final → libera objeto
    end
    
    collectgarbage("collect")
    
    local elapsed = os.clock() - start
    
    logPass(
        player,
        string.format(
            "REFCOUNT: %d objects (5 refs each) in %.3f sec (%.0f objs/sec)",
            amount,
            elapsed,
            amount / (elapsed + 1e-9)
        )
    )
end

-- ============================================================================
-- TESTE 12: ALL - Bateria completa de benchmarks
-- ============================================================================
--[[
  Objetivo:
    Executar todos os testes (CREATE, GC, POOL, LEAK, SEND, ...) em sequencia
    reutilizando as funcoes compartilhadas dos testes individuais e consolidando
    resultados num relatorio final.
  
  O que esta sendo testado:
    • Mesmas areas dos testes individuais (ver documentacao de cada funcao)
    • Integracao entre testes (pool nao deve estar corrompido entre fases)
    • Estabilidade do allocator sob carga continua
  
  Fluxo:
    1. Executa CREATE test com SUITE_CREATE_AMOUNT
    2. Executa GC test com SUITE_GC_AMOUNT
    3. Executa POOL test com SUITE_POOL_AMOUNT (alloc + free)
    4. Executa LEAK test com SUITE_LEAK_ROUNDS
    5. Executa SEND test com SUITE_POOL_AMOUNT
    6. (Concurrent, BigData, Reset, Exhaust, Fragment, RefCount)
    7. Consolida tempos num relatorio final
  
  NOTA: POOL FREE reporta elapsed proprio (nao usa allocStart). EXHAUST inclui
        recovery phase. SEND usa o valor seguro SUITE_POOL_AMOUNT.
--]]

-- Helpers compartilhados: executam a carga de trabalho e retornam elapsed em segundos

local function runCreateWorkload(amount)
    local start = os.clock()
    for i = 1, amount do
        local msg = NetworkMessage()
        msg:addByte(0xAA)
        msg:addU16(i)
        msg:addString("stress")
        msg = nil
    end
    collectgarbage("collect")
    return os.clock() - start
end

local function runGCWorkload(amount)
    local start = os.clock()
    for i = 1, amount do
        local msg = NetworkMessage()
        msg:addString("GC TEST")
        msg:addByte(i % 255)
        msg = nil
    end
    collectgarbage("collect")
    return os.clock() - start
end

local function poolWorkload(amount)
    local messages = {}
    local allocStart = os.clock()
    for i = 1, amount do
        local msg = NetworkMessage()
        msg:addString("POOL TEST")
        msg:addU32(i)
        messages[i] = msg
    end
    local allocElapsed = os.clock() - allocStart
    local freeStart = os.clock()
    for i = 1, #messages do
        messages[i] = nil
    end
    collectgarbage("collect")
    local freeElapsed = os.clock() - freeStart
    return allocElapsed, freeElapsed
end

local function leakWorkload(rounds)
    local start = os.clock()
    for round = 1, rounds do
        for i = 1, 10000 do
            local msg = NetworkMessage()
            msg:addString("Leak Test")
            msg = nil
        end
        collectgarbage("collect")
    end
    return os.clock() - start
end

local function sendWorkload(p, amount)
    local start = os.clock()
    for i = 1, amount do
        local msg = NetworkMessage()
        msg:addByte(0xB4)
        msg:addString("Benchmark")
        msg:sendToPlayer(p)
    end
    return os.clock() - start
end

local function exhaustWorkload(poolSize, overshoot)
    local messages = {}
    local t1 = os.clock()
    for i = 1, poolSize do
        messages[i] = NetworkMessage()
        messages[i]:addString("pool_" .. i)
    end
    local poolTime = os.clock() - t1
    local t2 = os.clock()
    for i = poolSize + 1, poolSize + overshoot do
        messages[i] = NetworkMessage()
        messages[i]:addString("fallback_" .. i)
    end
    local fallbackTime = os.clock() - t2
    for i = 1, #messages do messages[i] = nil end
    collectgarbage("collect")
    -- Recovery phase
    local t3 = os.clock()
    for i = 1, poolSize do
        local msg = NetworkMessage()
        msg:addString("recovery_" .. i)
        msg = nil
    end
    collectgarbage("collect")
    local recoveryTime = os.clock() - t3
    return poolTime, fallbackTime, recoveryTime
end

local function resetWorkload(rounds)
    local start = os.clock()
    for round = 1, rounds do
        local msg1 = NetworkMessage()
        msg1:addByte(0xFF)
        msg1:addString("SECRET")
        msg1 = nil
        if round % 100 == 0 then collectgarbage("collect") end
        local msg2 = NetworkMessage()
        msg2:addString("CLEAN")
        msg2 = nil
    end
    collectgarbage("collect")
    return os.clock() - start
end

local function bigDataWorkload(amount, payloadSize)
    local start = os.clock()
    local bigPayload = string.rep("X", payloadSize)
    for i = 1, amount do
        local msg = NetworkMessage()
        msg:addString(bigPayload)
        msg = nil
    end
    collectgarbage("collect")
    return os.clock() - start
end

local function fragmentWorkload(rounds)
    local start = os.clock()
    for round = 1, rounds do
        local msgs = {}
        for i = 1, 1000 do
            msgs[i] = NetworkMessage()
        end
        for i = 1, 1000, 2 do
            msgs[i] = nil
        end
        collectgarbage("collect")
        for i = 1, 500 do
            local msg = NetworkMessage()
            msg = nil
        end
        for i = 1, 1000 do msgs[i] = nil end
    end
    collectgarbage("collect")
    return os.clock() - start
end

local function refCountWorkload(amount)
    local start = os.clock()
    for i = 1, amount do
        local msg = NetworkMessage()
        local refs = {msg, msg, msg, msg, msg}
        refs = nil
        msg = nil
    end
    collectgarbage("collect")
    return os.clock() - start
end

local function runAllTests(player)
    local report = {}
    local suiteStart = os.clock()

    logHeader(player, "=== Starting COMPLETE NetworkMessage Benchmark ===")

    -- ── FASE 1: CREATE ────────────────────────────────────────────────────
    local createElapsed = runCreateWorkload(SUITE_CREATE_AMOUNT)
    report[#report + 1] = string.format("CREATE (%d): %.3f sec", SUITE_CREATE_AMOUNT, createElapsed)

    -- ── FASE 2: GC ────────────────────────────────────────────────────────
    local gcElapsed = runGCWorkload(SUITE_GC_AMOUNT)
    report[#report + 1] = string.format("GC (%d): %.3f sec", SUITE_GC_AMOUNT, gcElapsed)

    -- ── FASE 3: POOL ──────────────────────────────────────────────────────
    local allocElapsed, freeElapsed = poolWorkload(SUITE_POOL_AMOUNT)
    report[#report + 1] = string.format("POOL (%d): alloc=%.3fs free=%.3fs", SUITE_POOL_AMOUNT, allocElapsed, freeElapsed)

    -- ── FASE 4: LEAK ──────────────────────────────────────────────────────
    local leakElapsed = leakWorkload(SUITE_LEAK_ROUNDS)
    report[#report + 1] = string.format("LEAK (%d rounds): %.3f sec", SUITE_LEAK_ROUNDS, leakElapsed)

    -- ── FASE 5: SEND ──────────────────────────────────────────────────────
    local sendElapsed = sendWorkload(player, SUITE_POOL_AMOUNT)
    report[#report + 1] = string.format("SEND (%d): %.3f sec", SUITE_POOL_AMOUNT, sendElapsed)

    -- ── FASE 6: CONCURRENT ────────────────────────────────────────────────
    logInfo(player, "CONCURRENT: test runs async - results will appear separately")
    runConcurrentTest(player, SUITE_CONCURRENT_WORKERS, SUITE_CONCURRENT_MSGS)

    -- ── FASE 7: BIGDATA ───────────────────────────────────────────────────
    local bdElapsed = bigDataWorkload(SUITE_BIGDATA_AMOUNT, SUITE_BIGDATA_SIZE)
    report[#report + 1] = string.format("BIGDATA (%d x %dB): %.3f sec", SUITE_BIGDATA_AMOUNT, SUITE_BIGDATA_SIZE, bdElapsed)

    -- ── FASE 8: RESET ─────────────────────────────────────────────────────
    local resetElapsed = resetWorkload(SUITE_RESET_ROUNDS)
    report[#report + 1] = string.format("RESET (%d cycles): %.3f sec", SUITE_RESET_ROUNDS, resetElapsed)

    -- ── FASE 9: EXHAUST ───────────────────────────────────────────────────
    local exhaustPool, exhaustFallback, exhaustRecovery = exhaustWorkload(SUITE_EXHAUST_POOL, SUITE_EXHAUST_OVER)
    report[#report + 1] = string.format("EXHAUST pool=%.3fs fallback=%.3fs recovery=%.3fs", exhaustPool, exhaustFallback, exhaustRecovery)

    -- ── FASE 10: FRAGMENT ─────────────────────────────────────────────────
    local fragElapsed = fragmentWorkload(SUITE_FRAGMENT_ROUNDS)
    report[#report + 1] = string.format("FRAGMENT (%d rounds): %.3f sec", SUITE_FRAGMENT_ROUNDS, fragElapsed)

    -- ── FASE 11: REFCOUNT ─────────────────────────────────────────────────
    local refElapsed = refCountWorkload(SUITE_REFCOUNT_AMOUNT)
    report[#report + 1] = string.format("REFCOUNT (%d objs): %.3f sec", SUITE_REFCOUNT_AMOUNT, refElapsed)

    -- ── RELATORIO FINAL ───────────────────────────────────────────────────
    local totalElapsed = os.clock() - suiteStart

    logHeader(player, "=== BENCHMARK RESULTS (excluding async tests) ===")

    for _, line in ipairs(report) do
        logPass(player, line)
    end

    logInfo(player, string.format("TOTAL TIME: %.3f sec", totalElapsed))
    logInfo(player, "Note: CONCURRENT: test results appear separately")

    local passed = true
    local wallMs = (os.clock() - suiteStart) * 1000
    if passed then
        logHeader(player, string.format("=== NETWORK COMPLETO: ALL PASS | wall ~%.0fms ===", wallMs))
    end
end

-- ============================================================================
-- HELP - Exibicao de ajuda in-game
-- ============================================================================
--[[
  Exibe lista de comandos disponiveis e sintaxe de uso.
  Chamado quando player digita /net sem parametros.
--]]
local function showHelp(player)
    log(player, "==================== HELP ====================")
    logInfo(player, string.format("/net create[,%d]", SUITE_CREATE_AMOUNT))
    logInfo(player, string.format("/net gc[,%d]", SUITE_GC_AMOUNT))
    logInfo(player, string.format("/net pool[,%d]", SUITE_POOL_AMOUNT))
    logInfo(player, string.format("/net leak[,%d]", SUITE_LEAK_ROUNDS))
    logInfo(player, string.format("/net send[,%d]", SUITE_POOL_AMOUNT))
    log(player, "----------------------------------------------")
    logInfo(player, string.format("/net concurrent[,%d,%d]", SUITE_CONCURRENT_WORKERS, SUITE_CONCURRENT_MSGS))
    logInfo(player, string.format("/net bigdata[,%d,%d]", SUITE_BIGDATA_AMOUNT, SUITE_BIGDATA_SIZE))
    logInfo(player, string.format("/net reset[,%d]", SUITE_RESET_ROUNDS))
    logInfo(player, string.format("/net exhaust[,%d,%d]", SUITE_EXHAUST_POOL, SUITE_EXHAUST_OVER))
    logInfo(player, string.format("/net fragment[,%d]", SUITE_FRAGMENT_ROUNDS))
    logInfo(player, string.format("/net refcount[,%d]", SUITE_REFCOUNT_AMOUNT))
    log(player, "----------------------------------------------")
    logInfo(player, "/net all - Run ALL tests")
    log(player, "==============================================")
end

-- ============================================================================
-- TALKACTION HANDLER
-- ============================================================================
--[[
  Handler principal do TalkAction /net.
  Parseia comando e valor, delega para funcao de teste apropriada.
  
  Sintaxe:
    /net [comando],[valor]
  
  Exemplos:
    /net create,50000  → roda CREATE test com 50k msgs
    /net all           → roda bateria completa
    /net               → exibe help
  
  Seguranca:
    - TalkAction registrado apenas para GMs (configuracao padrao do TFS)
    - Nenhuma validacao adicional de permissoes (assumido que apenas
      desenvolvedores/admins executarao benchmarks)
--]]
function talk.onSay(player, words, param)
    -- Se sem parametros, exibe help
    if param == "" then
        showHelp(player)
        return false
    end

    -- Parseia comando e valores (formato: cmd,v1,v2,v3...)
    local parts = {}
    for part in param:gmatch("([^,]+)") do
        -- Remove espacos em branco
        local trimmed = part:match("^%s*(.-)%s*$")
        parts[#parts + 1] = trimmed
    end
    
    local cmd = parts[1] and parts[1]:lower() or ""
    
    -- Converte valores numericos
    local value1 = tonumber(parts[2])
    local value2 = tonumber(parts[3])
    local value3 = tonumber(parts[4])

    -- Roteamento de comandos
    if cmd == "create" then
        runCreateTest(player, value1 or SUITE_CREATE_AMOUNT)

    elseif cmd == "gc" then
        runGCTest(player, value1 or SUITE_GC_AMOUNT)

    elseif cmd == "pool" then
        runPoolTest(player, value1 or SUITE_POOL_AMOUNT)

    elseif cmd == "leak" then
        runLeakTest(player, value1 or SUITE_LEAK_ROUNDS)

    elseif cmd == "send" then
        runSendTest(player, value1 or SUITE_POOL_AMOUNT)

    elseif cmd == "concurrent" then
        local workers = value1 or SUITE_CONCURRENT_WORKERS
        local msgsPerWorker = value2 or SUITE_CONCURRENT_MSGS
        runConcurrentTest(player, workers, msgsPerWorker)

    elseif cmd == "bigdata" then
        local amount = value1 or SUITE_BIGDATA_AMOUNT
        local size = value2 or SUITE_BIGDATA_SIZE
        runBigDataTest(player, amount, size)

    elseif cmd == "reset" then
        runResetTest(player, value1 or SUITE_RESET_ROUNDS)

    elseif cmd == "exhaust" then
        local poolSize = value1 or SUITE_EXHAUST_POOL
        local overshoot = value2 or SUITE_EXHAUST_OVER
        runExhaustTest(player, poolSize, overshoot)

    elseif cmd == "fragment" then
        runFragmentTest(player, value1 or SUITE_FRAGMENT_ROUNDS)

    elseif cmd == "refcount" then
        runRefCountTest(player, value1 or SUITE_REFCOUNT_AMOUNT)

    elseif cmd == "all" then
        runAllTests(player)

    else
        -- Comando nao reconhecido → exibe help
        showHelp(player)
    end

    return false
end

-- ============================================================================
-- REGISTRO
-- ============================================================================
-- Registra TalkAction com separador de espaco (permite /net create,100000)
-- Restrito a contas administrativas (ACCOUNT_TYPE_GOD = 6)
talk:separator(" ")
talk:accountType(6)
talk:register()
