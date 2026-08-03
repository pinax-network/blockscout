# SPDX-License-Identifier: LicenseRef-Blockscout
defmodule Explorer.Repo.Migrations.AddClaimLeaseToMissingBlockRanges do
  use Ecto.Migration

  def change do
    alter table(:missing_block_ranges) do
      add(:claim_id, :uuid)
      add(:claim_expires_at, :utc_datetime_usec)
    end

    create(index(:missing_block_ranges, [:claim_id], where: "claim_id IS NOT NULL"))
    create(index(:missing_block_ranges, [:claim_expires_at], where: "claim_id IS NOT NULL"))

    create(
      constraint(:missing_block_ranges, :missing_block_ranges_claim_lease_is_complete,
        check: "(claim_id IS NULL) = (claim_expires_at IS NULL)"
      )
    )
  end
end
