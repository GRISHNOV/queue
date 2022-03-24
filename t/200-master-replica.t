#!/usr/bin/env tarantool

local fio   = require('fio')
local log   = require('log')
local tnt   = require('t.tnt')
local test  = require('tap').test('')
local uuid  = require('uuid')
local queue = require('queue')
local fiber = require('fiber')

local queue_state = require('queue.abstract.queue_state')
rawset(_G, 'queue', require('queue'))

local qc = require('queue.compat')
if not qc.check_version({2, 4, 1}) then
    log.info('Tests skipped, tarantool version < 2.4.1')
    return
end

-- Replica connection handler
local conn = {}

test:plan(5)

test:test('Check master-replica setup', function(test)
    test:plan(8)
    local engine = os.getenv('ENGINE') or 'memtx'
    tnt.cluster.cfg{}

    test:ok(rawget(box, 'space'), 'box started')
    test:ok(queue, 'queue is loaded')

    test:ok(tnt.cluster.wait_replica(), 'wait for replica to connect')
    conn = tnt.cluster.connect_replica()
    test:ok(conn.error == nil, 'no errors on connect to replica')
    test:ok(conn:ping(), 'ping replica')
    test:is(queue.state(), 'RUNNING', 'check master queue state')
    conn:eval('rawset(_G, "queue", require("queue"))')
    test:is(conn:call('queue.state'), 'INIT', 'check replica queue state')

    -- Setup tube. Set ttr = 0.5 for sessions expire testing.
    conn:call('queue.cfg', {{ttr = 0.5}})
    queue.cfg{ttr = 0.5}
    local tube = queue.create_tube('test', 'fifo', {engine = engine})
    test:ok(tube, 'test tube created')
end)

test:test('Check queue state switching', function(test)
    test:plan(2)
    box.cfg{read_only = true}
    test:ok(queue_state.poll(queue_state.states.WAITING, 10),
        "queue state changed to waiting")
    box.cfg{read_only = false}
    test:ok(queue_state.poll(queue_state.states.RUNNING, 10),
        "queue state changed to running")
end)

test:test('Check session resuming', function(test)
    test:plan(17)
    local client = tnt.cluster.connect_master()
    test:ok(client.error == nil, 'no errors on client connect to master')
    local session_uuid = client:call('queue.identify')
    local uuid_obj = uuid.frombin(session_uuid)

    test:ok(queue.tube.test:put('testdata'), 'put task')
    local task_master = client:call('queue.tube.test:take')
    test:ok(task_master, 'task was taken')
    test:is(task_master[3], 'testdata', 'task.data')
    client:close()

    local qt = box.space._queue_taken_2:select()
    test:is(uuid.frombin(qt[1][4]):str(), uuid_obj:str(),
        'task taken by actual uuid')

    -- wait for disconnect collback
    local attempts = 0
    while true do
        local is = box.space._queue_inactive_sessions:select()

        if is[1] then
            test:is(uuid.frombin(is[1][1]):str(), uuid_obj:str(),
                'check inactive sessions')
            break
        end

        attempts = attempts + 1
        if attempts == 10 then
            test:ok(false, 'check inactive sessions')
            return false
        end
        fiber.sleep(0.01)
    end

    -- switch roles
    box.cfg{read_only = true}
    queue_state.poll(queue_state.states.WAITING, 10)
    test:is(queue.state(), 'WAITING', 'master state is waiting')
    conn:eval('box.cfg{read_only=false}')
    conn:eval([[
        queue_state = require('queue.abstract.queue_state')
        queue_state.poll(queue_state.states.RUNNING, 10)
    ]])
    test:is(conn:call('queue.state'), 'RUNNING', 'replica state is running')

    local cfg = conn:eval('return queue.cfg')
    test:is(cfg.ttr, 0.5, 'check cfg applied after lazy start')

    test:ok(conn:call('queue.identify', {session_uuid}), 'identify old session')
    local stat = conn:call('queue.statistics')
    test:is(stat.test.tasks.taken, 1, 'taken tasks count')
    test:is(stat.test.tasks.done, 0, 'done tasks count')
    local task_replica = conn:call('queue.tube.test:ack', {task_master[1]})
    test:is(task_replica[3], 'testdata', 'check task data')
    local stat = conn:call('queue.statistics')
    test:is(stat.test.tasks.taken, 0, 'taken tasks count after ack()')
    test:is(stat.test.tasks.done, 1, 'done tasks count after ack()')

    -- switch roles back
    conn:eval('box.cfg{read_only=true}')
    conn:eval([[
        queue_state = require('queue.abstract.queue_state')
        queue_state.poll(queue_state.states.WAITING, 10)
    ]])
    box.cfg{read_only = false}
    queue_state.poll(queue_state.states.RUNNING, 10)
    test:is(queue.state(), 'RUNNING', 'master state is running')
    test:is(conn:call('queue.state'), 'WAITING', 'replica state is waiting')
end)

test:test('Check task is cleaned after migrate', function(test)
    test:plan(9)
    local client = tnt.cluster.connect_master()
    local session_uuid = client:call('queue.identify')
    local uuid_obj = uuid.frombin(session_uuid)
    test:ok(queue.tube.test:put('testdata'), 'put task')
    test:ok(client:call('queue.tube.test:take'), 'take task from master')
    client:close()

    -- wait for disconnect collback
    local attempts = 0
    while true do
        local is = box.space._queue_inactive_sessions:select()

        if is[1] then
            test:is(uuid.frombin(is[1][1]):str(), uuid_obj:str(),
                'check inactive sessions')
            break
        end

        attempts = attempts + 1
        if attempts == 10 then
            test:ok(false, 'check inactive sessions')
            return false
        end
        fiber.sleep(0.01)
    end

    -- switch roles
    box.cfg{read_only = true}

    queue_state.poll(queue_state.states.WAITING, 10)
    test:is(queue.state(), 'WAITING', 'master state is waiting')
    conn:eval('box.cfg{read_only=false}')
    conn:eval([[
        queue_state = require('queue.abstract.queue_state')
        queue_state.poll(queue_state.states.RUNNING, 10)
    ]])
    test:is(conn:call('queue.state'), 'RUNNING', 'replica state is running')

    -- check task
    local stat = conn:call('queue.statistics')
    test:is(stat.test.tasks.taken, 1, 'taken tasks count before timeout')
    fiber.sleep(1)
    local stat = conn:call('queue.statistics')
    test:is(stat.test.tasks.taken, 0, 'taken tasks count after timeout')

    -- switch roles back
    conn:eval('box.cfg{read_only=true}')
    conn:eval([[
        queue_state = require('queue.abstract.queue_state')
        queue_state.poll(queue_state.states.WAITING, 10)
    ]])
    box.cfg{read_only = false}
    queue_state.poll(queue_state.states.RUNNING, 10)
    test:is(queue.state(), 'RUNNING', 'master state is running')
    test:is(conn:call('queue.state'), 'WAITING', 'replica state is waiting')
end)

test:test('Check release_all method', function(test)
    test:plan(6)
    test:ok(queue.tube.test:put('testdata'), 'put task #0')
    test:ok(queue.tube.test:put('testdata'), 'put task #1')
    test:ok(queue.tube.test:take(), 'take task #0')
    test:ok(queue.tube.test:take(), 'take task #1')
    test:is(queue.statistics().test.tasks.taken, 2,
        'taken tasks count before release_all')
    queue.tube.test:release_all()
    test:is(queue.statistics().test.tasks.taken, 0,
        'taken tasks count after release_all')
end)

rawset(_G, 'queue', nil)
conn:eval('rawset(_G, "queue", nil)')
conn:close()
tnt.finish()
os.exit(test:check() and 0 or 1)
-- vim: set ft=lua :