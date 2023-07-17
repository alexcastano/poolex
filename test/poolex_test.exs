defmodule PoolexTest do
  use ExUnit.Case, async: false
  doctest Poolex

  @moduletag capture_log: true

  describe "debug info" do
    test "valid after initialization" do
      initial_fun = fn -> 0 end

      pool_name = start_pool(worker_module: Agent, worker_args: [initial_fun], workers_count: 5)

      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.__struct__ == Poolex.DebugInfo
      assert debug_info.busy_workers_count == 0
      assert debug_info.busy_workers_impl == Poolex.Workers.Impl.List
      assert debug_info.busy_workers_pids == []
      assert debug_info.idle_workers_count == 5
      assert debug_info.idle_workers_impl == Poolex.Workers.Impl.List
      assert debug_info.max_overflow == 0
      assert Enum.count(debug_info.idle_workers_pids) == 5
      assert debug_info.worker_module == Agent
      assert debug_info.worker_args == [initial_fun]
      assert debug_info.waiting_callers == []
      assert debug_info.waiting_callers_impl == Poolex.Callers.Impl.ErlangQueue
    end

    test "valid configured implementations" do
      pool_name =
        start_pool(
          worker_module: SomeWorker,
          workers_count: 10,
          busy_workers_impl: SomeBusyWorkersImpl,
          idle_workers_impl: SomeIdleWorkersImpl,
          waiting_callers_impl: SomeWaitingCallersImpl
        )

      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.busy_workers_impl == SomeBusyWorkersImpl
      assert debug_info.idle_workers_impl == SomeIdleWorkersImpl
      assert debug_info.waiting_callers_impl == SomeWaitingCallersImpl
    end

    test "valid after holding some workers" do
      initial_fun = fn -> 0 end
      pool_name = start_pool(worker_module: Agent, worker_args: [initial_fun], workers_count: 5)

      test_process = self()

      spawn(fn ->
        Poolex.run(pool_name, fn _pid ->
          Process.send(test_process, nil, [])
          :timer.sleep(:timer.seconds(5))
        end)
      end)

      receive do
        _message -> nil
      end

      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.__struct__ == Poolex.DebugInfo
      assert debug_info.busy_workers_count == 1
      assert Enum.count(debug_info.busy_workers_pids) == 1
      assert debug_info.idle_workers_count == 4
      assert Enum.count(debug_info.idle_workers_pids) == 4
      assert debug_info.worker_module == Agent
      assert debug_info.worker_args == [initial_fun]
      assert debug_info.waiting_callers == []
    end
  end

  describe "run/2" do
    test "updates agent's state" do
      pool_name = start_pool(worker_module: Agent, worker_args: [fn -> 0 end], workers_count: 1)

      Poolex.run(pool_name, fn pid -> Agent.update(pid, fn _state -> 1 end) end)

      [agent_pid] = Poolex.get_debug_info(pool_name).idle_workers_pids

      assert 1 == Agent.get(agent_pid, fn state -> state end)
    end

    test "get result from custom worker" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 2)

      result = Poolex.run(pool_name, fn pid -> GenServer.call(pid, :do_some_work) end)
      assert result == {:ok, :some_result}

      result = Poolex.run!(pool_name, fn pid -> GenServer.call(pid, :do_some_work) end)
      assert result == :some_result
    end

    test "test waiting queue" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 5)

      result =
        1..20
        |> Enum.map(fn _ ->
          Task.async(fn -> Poolex.run!(pool_name, &SomeWorker.long_task(&1, 100)) end)
        end)
        |> Enum.map(&Task.await/1)

      assert length(result) == 20
      assert Enum.all?(result, &(&1 == :some_result))
    end
  end

  describe "restarting terminated processes" do
    test "works on idle workers" do
      pool_name = start_pool(worker_module: Agent, worker_args: [fn -> 0 end], workers_count: 1)

      [agent_pid] = Poolex.get_debug_info(pool_name).idle_workers_pids

      Process.exit(agent_pid, :kill)

      # To be sure that DOWN message will be handed
      :timer.sleep(1)

      [new_agent_pid] = Poolex.get_debug_info(pool_name).idle_workers_pids

      assert agent_pid != new_agent_pid
    end

    test "works on busy workers" do
      pool_name = start_pool(worker_module: Agent, worker_args: [fn -> 0 end], workers_count: 1)

      test_process = self()

      spawn(fn ->
        Poolex.run(pool_name, fn _pid ->
          Process.send(test_process, nil, [])
          :timer.sleep(:timer.seconds(5))
        end)
      end)

      receive do
        _message -> nil
      end

      [agent_pid] = Poolex.get_debug_info(pool_name).busy_workers_pids

      Process.exit(agent_pid, :kill)

      # To be sure that DOWN message will be handed
      :timer.sleep(1)

      [new_agent_pid] = Poolex.get_debug_info(pool_name).idle_workers_pids

      assert agent_pid != new_agent_pid
    end

    test "works on callers" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)

      1..10
      |> Enum.each(fn _ ->
        spawn(fn -> Poolex.run(pool_name, &SomeWorker.long_task(&1, :timer.seconds(4))) end)
      end)

      waiting_caller =
        spawn(fn ->
          Poolex.run(pool_name, &SomeWorker.long_task(&1, :timer.seconds(3)))
        end)

      :timer.sleep(10)

      debug_info = Poolex.get_debug_info(pool_name)
      assert length(debug_info.waiting_callers) == 10

      assert Enum.find(debug_info.waiting_callers, fn {pid, _} ->
               pid == waiting_caller
             end)

      Process.exit(waiting_caller, :kill)
      :timer.sleep(10)

      debug_info = Poolex.get_debug_info(pool_name)
      assert length(debug_info.waiting_callers) == 9

      refute Enum.find(debug_info.waiting_callers, fn {pid, _} ->
               pid == waiting_caller
             end)
    end

    test "runtime errors" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)

      catch_exit(Poolex.run(pool_name, fn pid -> GenServer.call(pid, :do_raise) end))

      :timer.sleep(10)

      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.busy_workers_count == 0
      assert debug_info.idle_workers_count == 1
      assert debug_info.idle_workers_pids |> hd() |> Process.alive?()
    end
  end

  describe "timeouts" do
    test "handles caller timeout" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)

      delay = 100
      assert {:ok, :some_result} = Poolex.run(pool_name, &SomeWorker.long_task(&1, delay, 1000))

      assert {:timeout, _} =
               catch_exit(Poolex.run(pool_name, &SomeWorker.long_task(&1, delay, 1)))
    end

    test "handles checkout timeout" do
      test_pid = self()
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)

      delay = 100

      process_1 =
        spawn(fn ->
          assert {:ok, :some_result} =
                   Poolex.run(pool_name, fn pid ->
                     send(test_pid, {:worker, pid})
                     SomeWorker.long_task(pid, delay)
                   end)
        end)

      ref_1 = Process.monitor(process_1)

      process_2 =
        spawn(fn ->
          opts = [checkout_timeout: 0]

          assert {:error, :checkout_timeout} =
                   Poolex.run(pool_name, &SomeWorker.long_task(&1, delay), opts)

          send(test_pid, {:waiting, self()})

          receive do
            :finish -> :ok
          end
        end)

      ref_2 = Process.monitor(process_2)

      assert_receive {:worker, worker}, 1000
      assert_receive {:waiting, ^process_2}, 1000
      assert_receive {:DOWN, ^ref_1, :process, ^process_1, _}, 1000
      refute_received _

      Process.sleep(100)
      debug_info = Poolex.get_debug_info(pool_name)
      # FIXME!
      # assert %{busy_workers_pids: []} = debug_info
      assert %{busy_workers_pids: [^worker]} = debug_info

      send(process_2, :finish)
      assert_receive {:DOWN, ^ref_2, :process, ^process_2, _}
    end

    test "when caller waits too long" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)

      launch_long_task(pool_name)

      waiting_caller =
        spawn(fn ->
          Poolex.run(pool_name, &SomeWorker.long_task(&1, 4000), checkout_timeout: 100)
        end)

      :timer.sleep(10)

      debug_info = Poolex.get_debug_info(pool_name)
      assert length(debug_info.waiting_callers) == 1

      assert Enum.find(debug_info.waiting_callers, fn {pid, _} ->
               pid == waiting_caller
             end)

      :timer.sleep(100)
      debug_info = Poolex.get_debug_info(pool_name)
      assert Enum.empty?(debug_info.waiting_callers)
    end

    test "run/3 returns {:error, :checkout_timeout} on timeout" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)
      launch_long_task(pool_name)

      result = Poolex.run(pool_name, &SomeWorker.long_task(&1, 4000), checkout_timeout: 100)

      assert result == {:error, :checkout_timeout}
    end

    test "run!/3 raises on checkout timeout" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)
      launch_long_task(pool_name)

      assert_raise RuntimeError, fn ->
        opts = [checkout_timeout: 100]
        Poolex.run!(pool_name, &SomeWorker.long_task(&1, 4000), opts)
      end
    end
  end

  describe "overflow" do
    test "create new workers when possible" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1, max_overflow: 5)

      launch_long_tasks(pool_name, 5)

      debug_info = Poolex.get_debug_info(pool_name)
      assert debug_info.max_overflow == 5
      assert debug_info.busy_workers_count == 5
      assert debug_info.overflow == 4
    end

    test "return error when max count of workers reached" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)
      launch_long_task(pool_name)

      result = Poolex.run(pool_name, &SomeWorker.long_task(&1, 4000), checkout_timeout: 100)

      assert result == {:error, :checkout_timeout}

      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.busy_workers_count == 1
      assert debug_info.max_overflow == 0
      assert debug_info.overflow == 0
    end

    test "all workers running over the limit are turned off after use" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1, max_overflow: 2)

      launch_long_task(pool_name)

      spawn(fn -> Poolex.run(pool_name, &is_pid/1) end)
      spawn(fn -> Poolex.run(pool_name, &is_pid/1) end)

      :timer.sleep(50)

      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.busy_workers_count == 1
      assert debug_info.idle_workers_count == 0
      assert debug_info.overflow == 0
    end

    test "allows workers_count: 0" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 0, max_overflow: 2)
      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.idle_workers_count == 0
      assert debug_info.idle_workers_pids == []
      assert debug_info.busy_workers_count == 0
      assert debug_info.busy_workers_pids == []
      assert debug_info.overflow == 0

      pid = self()

      spawn(fn ->
        Poolex.run!(pool_name, fn server ->
          SomeWorker.traceable_call(server, pid, :foo, 50)
        end)
      end)

      assert_receive {:traceable_start, :foo, worker_pid}
      refute_received {:traceable_end, _, _}

      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.idle_workers_count == 0
      assert debug_info.idle_workers_pids == []
      assert debug_info.busy_workers_count == 1
      assert debug_info.busy_workers_pids == [worker_pid]
      assert debug_info.overflow == 1

      assert_receive {:traceable_end, :foo, ^worker_pid}
      debug_info = Poolex.get_debug_info(pool_name)

      assert debug_info.idle_workers_count == 0
      assert debug_info.idle_workers_pids == []
      assert debug_info.busy_workers_count == 0
      assert debug_info.busy_workers_pids == []
      assert debug_info.overflow == 0
    end
  end

  describe "child_spec" do
    test "child_spec/1" do
      assert Poolex.child_spec(pool_id: :test_pool, worker_module: SomeWorker, workers_count: 5) ==
               %{
                 id: :test_pool,
                 start:
                   {Poolex, :start_link,
                    [[pool_id: :test_pool, worker_module: SomeWorker, workers_count: 5]]}
               }
    end
  end

  describe "terminate process" do
    test "workers stop before the pool with reason :normal" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)
      pool_pid = Process.whereis(pool_name)

      state = Poolex.get_state(pool_name)

      supervisor_pid = state.supervisor
      worker_pid = Poolex.run!(pool_name, fn pid -> pid end)

      pool_monitor_ref = Process.monitor(pool_pid)
      supervisor_monitor_ref = Process.monitor(supervisor_pid)
      worker_monitor_ref = Process.monitor(worker_pid)

      GenServer.stop(pool_name)

      {:messages, [message_1, message_2, message_3]} = Process.info(self(), :messages)

      assert message_1 == {:DOWN, worker_monitor_ref, :process, worker_pid, :shutdown}
      assert message_2 == {:DOWN, supervisor_monitor_ref, :process, supervisor_pid, :normal}
      assert message_3 == {:DOWN, pool_monitor_ref, :process, pool_pid, :normal}
    end

    test "workers stop before the pool with reason :exit" do
      pool_name = start_pool(worker_module: SomeWorker, workers_count: 1)
      pool_pid = Process.whereis(pool_name)

      state = Poolex.get_state(pool_name)

      supervisor_pid = state.supervisor
      worker_pid = Poolex.run!(pool_name, fn pid -> pid end)

      pool_monitor_ref = Process.monitor(pool_pid)
      supervisor_monitor_ref = Process.monitor(supervisor_pid)
      worker_monitor_ref = Process.monitor(worker_pid)

      Process.exit(pool_pid, :exit)
      :timer.sleep(20)

      {:messages, [message_1, message_2, message_3]} = Process.info(self(), :messages)

      assert {:DOWN, worker_monitor_ref, :process, worker_pid, :shutdown} == message_1
      assert {:DOWN, ^supervisor_monitor_ref, :process, ^supervisor_pid, _} = message_2
      assert {:DOWN, ^pool_monitor_ref, :process, ^pool_pid, _} = message_3
    end
  end

  describe "checkout/2" do
    test "demonitors when checkout is cancelled" do
      pool_name = start_pool(workers_count: 1)
      test_pid = self()

      pid_1 =
        spawn(fn ->
          Poolex.run(pool_name, fn _pid ->
            assert_receive :finish, 5000
          end)
        end)

      pid_2 =
        spawn(fn ->
          assert {:error, :checkout_timeout} =
                   Poolex.run(pool_name, fn _pid -> :ok end, checkout_timeout: 1000)

          send(test_pid, {:failed, self()})
          assert_receive :finish, 5000
        end)

      Process.sleep(500)
      refute_received {:failed, ^pid_2}
      assert get_monitors(pool_name) |> length() == 2
      assert_receive {:failed, ^pid_2}, 1000
      assert get_monitors(pool_name) |> length() == 1
      send(pid_1, :finish)
      send(pid_2, :finish)
    end
  end

  defp start_pool(options) do
    options = Keyword.merge([worker_module: SomeWorker], options)

    pool_name =
      1..10
      |> Enum.map(fn _ -> Enum.random(?a..?z) end)
      |> to_string()
      |> String.to_atom()

    options = Keyword.put(options, :pool_id, pool_name)
    {:ok, _pid} = start_supervised({Poolex, options})

    pool_name
  end

  defp launch_long_task(pool_id, delay \\ :timer.seconds(4)) do
    launch_long_tasks(pool_id, 1, delay)
  end

  defp launch_long_tasks(pool_id, count, delay \\ :timer.seconds(4)) do
    for _i <- 1..count do
      spawn(fn ->
        Poolex.run(pool_id, &SomeWorker.long_task(&1, delay), checkout_timeout: 100)
      end)
    end

    :timer.sleep(10)
  end

  defp get_monitors(pool_name) do
    pid = Process.whereis(pool_name)
    # Synchronise with the Pid to ensure it has handled all expected work.
    _ = :sys.get_status(pid)
    [{:monitors, monitors}] = Process.info(pid, [:monitors])
    monitors
  end
end
