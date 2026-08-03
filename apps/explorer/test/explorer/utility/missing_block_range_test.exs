# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Utility.MissingBlockRangeTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Explorer.Repo
  alias Explorer.Utility.MissingBlockRange

  describe "add_ranges_by_block_numbers/2" do
    setup do
      # Ensure the database is clean before each test
      Repo.delete_all(MissingBlockRange)

      on_exit(fn ->
        # Clean up the database after each test
        Repo.delete_all(MissingBlockRange)
      end)

      :ok
    end

    test "adds ranges for a list of block numbers with a given priority" do
      block_numbers = [1, 2, 3, 5, 6, 10]
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 3

      assert Enum.any?(ranges, fn range ->
               range.from_number == 3 and range.to_number == 1 and range.priority == priority
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 6 and range.to_number == 5 and range.priority == priority
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 10 and range.to_number == 10 and range.priority == priority
             end)
    end

    test "handles an empty list of block numbers" do
      block_numbers = []
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert ranges == []
    end

    test "adds ranges with nil priority" do
      block_numbers = [15, 16, 20]
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 2

      assert Enum.any?(ranges, fn range ->
               range.from_number == 16 and range.to_number == 15 and is_nil(range.priority)
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 20 and range.to_number == 20 and is_nil(range.priority)
             end)
    end

    test "handles case when applying range with priority = nil overlaps with an different existing ranges in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 6, to_number: 3, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 10, to_number: 8, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 15, to_number: 12, priority: nil})

      block_numbers = 5..13 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 4

      assert Enum.any?(ranges, fn range ->
               range.from_number == 15 and range.to_number == 11 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 10 and range.to_number == 8 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 7 and range.to_number == 7 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 6 and range.to_number == 3 and range.priority == 1
             end)
    end

    # failed
    test "handles case when applying range with priority = 1 overlaps with an different existing ranges in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 6, to_number: 3, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 10, to_number: 8, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 15, to_number: 12, priority: nil})

      block_numbers = 5..13 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 2

      assert Enum.any?(ranges, fn range ->
               range.from_number == 15 and range.to_number == 14 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 13 and range.to_number == 3 and range.priority == 1
             end)
    end

    test "handles case when applying range with priority = nil overlaps with the same existing priority = 1 range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 12, to_number: 6, priority: 1})

      block_numbers = 7..10 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 1

      assert Enum.any?(ranges, fn range ->
               range.from_number == 12 and range.to_number == 6 and range.priority == 1
             end)
    end

    test "handles case when applying range with priority = nil overlaps with the same existing nil priority range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 12, to_number: 6, priority: nil})

      block_numbers = 7..10 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 1

      assert Enum.any?(ranges, fn range ->
               range.from_number == 12 and range.to_number == 6 and range.priority == nil
             end)
    end

    test "handles case when applying range with priority = 1 overlaps with the same existing priority = 1 range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 12, to_number: 6, priority: 1})

      block_numbers = 7..10 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 1

      assert Enum.any?(ranges, fn range ->
               range.from_number == 12 and range.to_number == 6 and range.priority == 1
             end)
    end

    test "handles case when applying range with priority = 1 overlaps with the same existing nil priority range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 12, to_number: 6, priority: nil})

      block_numbers = 7..10 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 3

      assert Enum.any?(ranges, fn range ->
               range.from_number == 12 and range.to_number == 11 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 10 and range.to_number == 7 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 6 and range.to_number == 6 and range.priority == nil
             end)
    end

    test "handles case when applying range with nil priority doesn't overlap with the existing different ranges in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 5, to_number: 4, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 8, to_number: 7, priority: 1})

      block_numbers = 3..10 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 3

      assert Enum.any?(ranges, fn range ->
               range.from_number == 6 and range.to_number == 3 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 8 and range.to_number == 7 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 10 and range.to_number == 9 and range.priority == nil
             end)
    end

    test "handles case when applying range with 1 priority doesn't overlap with the existing different ranges in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 5, to_number: 4, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 8, to_number: 7, priority: 1})

      block_numbers = 3..10 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 1

      assert Enum.any?(ranges, fn range ->
               range.from_number == 10 and range.to_number == 3 and range.priority == 1
             end)
    end

    test "handles case when left of the applying range with nil priority overlaps with the nil priority existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 112, to_number: 86, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 25, to_number: 20, priority: nil})

      block_numbers = 7..110 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 3

      assert Enum.any?(ranges, fn range ->
               range.from_number == 112 and range.to_number == 46 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 45 and range.to_number == 30 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 29 and range.to_number == 7 and range.priority == nil
             end)
    end

    test "handles case when left of the applying range with nil priority overlaps with the priority = 1 existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 112, to_number: 86, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 25, to_number: 20, priority: nil})

      block_numbers = 7..110 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 4

      assert Enum.any?(ranges, fn range ->
               range.from_number == 112 and range.to_number == 86 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 85 and range.to_number == 46 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 45 and range.to_number == 30 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 29 and range.to_number == 7 and range.priority == nil
             end)
    end

    test "handles case when left of the applying range with priority = 1 overlaps with the nil priority existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 112, to_number: 86, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 25, to_number: 20, priority: nil})

      block_numbers = 7..110 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 2

      assert Enum.any?(ranges, fn range ->
               range.from_number == 112 and range.to_number == 111 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 110 and range.to_number == 7 and range.priority == 1
             end)
    end

    test "handles case when left of the applying range with priority = 1 overlaps with the priority = 1 existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 112, to_number: 86, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 25, to_number: 20, priority: nil})

      block_numbers = 7..110 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 1

      assert Enum.any?(ranges, fn range ->
               range.from_number == 112 and range.to_number == 7 and range.priority == 1
             end)
    end

    test "handles case when right of the applying range with nil priority overlaps with the nil priority existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 130, to_number: 46, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 29, to_number: 20, priority: nil})

      block_numbers = 23..130 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 3

      assert Enum.any?(ranges, fn range ->
               range.from_number == 130 and range.to_number == 46 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 45 and range.to_number == 30 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 29 and range.to_number == 20 and range.priority == nil
             end)
    end

    test "handles case when right of the applying range with nil priority overlaps with the priority = 1 existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 130, to_number: 46, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 29, to_number: 20, priority: 1})

      block_numbers = 23..130 |> Enum.to_list()
      priority = nil

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 3

      assert Enum.any?(ranges, fn range ->
               range.from_number == 130 and range.to_number == 46 and range.priority == nil
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 45 and range.to_number == 30 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 29 and range.to_number == 20 and range.priority == 1
             end)
    end

    test "handles case when right of the applying range with priority = 1 overlaps with the nil priority existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 130, to_number: 46, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 29, to_number: 20, priority: nil})

      block_numbers = 23..130 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 2

      assert Enum.any?(ranges, fn range ->
               range.from_number == 130 and range.to_number == 23 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 22 and range.to_number == 20 and range.priority == nil
             end)
    end

    test "handles case when right of the applying range with priority = 1 overlaps with the priority = 1 existing range in the DB" do
      Repo.insert!(%MissingBlockRange{from_number: 130, to_number: 46, priority: nil})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 29, to_number: 20, priority: 1})

      block_numbers = 23..130 |> Enum.to_list()
      priority = 1

      MissingBlockRange.add_ranges_by_block_numbers(block_numbers, priority)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 1

      assert Enum.any?(ranges, fn range ->
               range.from_number == 130 and range.to_number == 20 and range.priority == 1
             end)
    end
  end

  describe "clear_batch/1" do
    setup do
      # Ensure the database is clean before each test
      Repo.delete_all(MissingBlockRange)

      on_exit(fn ->
        # Clean up the database after each test
        Repo.delete_all(MissingBlockRange)
      end)

      :ok
    end

    test "correctly clears the batch" do
      Repo.insert!(%MissingBlockRange{from_number: 112, to_number: 86, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 45, to_number: 30, priority: 1})
      Repo.insert!(%MissingBlockRange{from_number: 25, to_number: 20, priority: nil})

      batch = [95..80//-1, 60..58//-1, 42..35//-1, 30..19//-1]

      MissingBlockRange.clear_batch(batch)

      ranges = Repo.all(MissingBlockRange)

      assert length(ranges) == 3

      assert Enum.any?(ranges, fn range ->
               range.from_number == 112 and range.to_number == 96 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 45 and range.to_number == 43 and range.priority == 1
             end)

      assert Enum.any?(ranges, fn range ->
               range.from_number == 34 and range.to_number == 31 and range.priority == 1
             end)
    end
  end

  describe "claim_latest_batch/2" do
    setup do
      Repo.delete_all(MissingBlockRange)

      on_exit(fn -> Repo.delete_all(MissingBlockRange) end)

      :ok
    end

    test "preserves priority ordering and atomically splits a partial range" do
      Repo.insert!(%MissingBlockRange{from_number: 200, to_number: 101})
      Repo.insert!(%MissingBlockRange{from_number: 50, to_number: 1, priority: 1})

      assert {:ok, %{id: claim_id, ranges: [50..21//-1]}} = MissingBlockRange.claim_latest_batch(30, 60_000)

      assert %MissingBlockRange{
               from_number: 50,
               to_number: 21,
               priority: 1,
               claim_id: ^claim_id,
               claim_expires_at: %DateTime{}
             } = Repo.get_by!(MissingBlockRange, from_number: 50)

      assert %MissingBlockRange{from_number: 20, to_number: 1, priority: 1, claim_id: nil} =
               Repo.get_by!(MissingBlockRange, from_number: 20)

      assert %MissingBlockRange{from_number: 200, to_number: 101, claim_id: nil} =
               Repo.get_by!(MissingBlockRange, from_number: 200)
    end

    test "two concurrent claimers receive disjoint block numbers" do
      Repo.insert!(%MissingBlockRange{from_number: 200, to_number: 101})
      Repo.insert!(%MissingBlockRange{from_number: 100, to_number: 1})

      parent = self()

      claimers =
        for _index <- 1..2 do
          Task.async(fn ->
            send(parent, {:ready, self()})

            receive do
              :claim -> MissingBlockRange.claim_latest_batch(100, 60_000)
            end
          end)
        end

      Enum.each(claimers, fn %Task{pid: pid} ->
        assert_receive {:ready, ^pid}
      end)

      Enum.each(claimers, &send(&1.pid, :claim))

      claimed_number_sets =
        Enum.map(claimers, fn claimer ->
          assert {:ok, %{ranges: ranges}} = Task.await(claimer)
          ranges |> Enum.flat_map(&Enum.to_list/1) |> MapSet.new()
        end)

      assert [first, second] = claimed_number_sets
      assert MapSet.disjoint?(first, second)
      assert MapSet.size(first) == 100
      assert MapSet.size(second) == 100
    end

    test "an expired claim can be recovered and fences the stale worker" do
      Repo.insert!(%MissingBlockRange{from_number: 20, to_number: 1})

      assert {:ok, %{id: stale_claim_id, ranges: [20..1//-1]}} =
               MissingBlockRange.claim_latest_batch(20, 10)

      Process.sleep(20)

      assert {:ok, %{id: recovered_claim_id, ranges: [20..1//-1]}} =
               MissingBlockRange.claim_latest_batch(20, 60_000)

      refute stale_claim_id == recovered_claim_id
      assert {:ok, []} = MissingBlockRange.complete_claim(stale_claim_id, Enum.to_list(20..1//-1))

      assert %MissingBlockRange{claim_id: ^recovered_claim_id} = Repo.one!(MissingBlockRange)
    end

    test "completes owned successes and releases failures with their priority" do
      Repo.insert!(%MissingBlockRange{from_number: 20, to_number: 1, priority: 1})

      assert {:ok, %{id: claim_id, ranges: [20..11//-1]}} = MissingBlockRange.claim_latest_batch(10, 60_000)
      assert {:ok, [20, 19, 17]} = MissingBlockRange.complete_claim(claim_id, [20, 19, 17, 999])

      missing_numbers =
        MissingBlockRange
        |> Repo.all()
        |> Enum.flat_map(fn range -> Enum.to_list(range.from_number..range.to_number//-1) end)
        |> Enum.sort(:desc)

      expected_missing_numbers = Enum.to_list(18..1//-1) -- [17]

      assert missing_numbers == expected_missing_numbers
      refute Repo.exists?(from(range in MissingBlockRange, where: not is_nil(range.claim_id)))
      assert Enum.all?(Repo.all(MissingBlockRange), &(&1.priority == 1))
    end

    test "renewing a claim prevents recovery" do
      Repo.insert!(%MissingBlockRange{from_number: 10, to_number: 1})

      assert {:ok, %{id: claim_id, ranges: [10..1//-1]}} = MissingBlockRange.claim_latest_batch(10, 20)
      Process.sleep(10)
      assert {1, nil} = MissingBlockRange.renew_claim(claim_id, 60_000)
      Process.sleep(15)

      assert {:ok, %{ranges: []}} = MissingBlockRange.claim_latest_batch(10, 60_000)
      assert %MissingBlockRange{claim_id: ^claim_id} = Repo.one!(MissingBlockRange)
    end

    test "priority updates preserve an active claim" do
      Repo.insert!(%MissingBlockRange{from_number: 20, to_number: 1})

      assert {:ok, %{id: claim_id, ranges: [20..11//-1]}} = MissingBlockRange.claim_latest_batch(10, 60_000)

      MissingBlockRange.add_ranges_by_block_numbers([15], 1)

      assert %MissingBlockRange{from_number: 20, to_number: 11, priority: 1, claim_id: ^claim_id} =
               Repo.get_by!(MissingBlockRange, from_number: 20)
    end

    test "ordinary range clearing preserves ownership of claimed remainders" do
      Repo.insert!(%MissingBlockRange{from_number: 20, to_number: 1})

      assert {:ok, %{id: claim_id, ranges: [20..1//-1]}} = MissingBlockRange.claim_latest_batch(20, 60_000)

      MissingBlockRange.clear_batch([18..17//-1])

      claimed_ranges = Repo.all(from(range in MissingBlockRange, order_by: [desc: range.from_number]))

      assert [
               %MissingBlockRange{from_number: 20, to_number: 19, claim_id: ^claim_id},
               %MissingBlockRange{from_number: 16, to_number: 1, claim_id: ^claim_id}
             ] = claimed_ranges
    end
  end
end
