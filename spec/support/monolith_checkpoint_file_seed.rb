# frozen_string_literal: true

# The rows behind spec/fixtures/files/timekeeping_handoff/monolith_checkpoint.json.
# Timekeeping's suite cannot reach the monolith's database, so it loads that
# file through its own load route instead;
# spec/lib/timekeeping/handoff/monolith_checkpoint_file_spec.rb proves the
# file is what the monolith store exports from these rows. Entry ids differ
# across companies because Timekeeping's entries are keyed by id alone.
module MonolithCheckpointFileSeed
  FILE = Rails.root.join("spec/fixtures/files/timekeeping_handoff/monolith_checkpoint.json")

  # A JSON null, a decimal finer than a float and a nested object in the
  # audits; a float with no short decimal form; a discarded entry; a committed
  # and an aborted operation; a receipt body whose spacing jsonb would rewrite;
  # a reservation linked to its operation and one that is not; a service audit.
  SQL = <<~SQL
    INSERT INTO entries (id, company_id, version, project_id, user_id, agent_id, work_date, duration, note,
                         bill_status, review_status, locked, source, source_metadata, external_run_id,
                         external_session_id, proof_url, proof_metadata, discarded_at, created_at, updated_at)
    VALUES
      (101, 1, 3, 11, 21, NULL, '2026-03-02', '0.30000000000000004'::float8, 'Design review', 'billed',
       'approved', true, 'manual', '{"tags": ["a", "b"], "rate": 1.00000000000000000001}', NULL, NULL, NULL,
       '{}', NULL, '2026-03-02 09:15:30.123456', '2026-03-02 10:00:00.654321'),
      (102, 1, 1, 11, 22, 31, '2026-03-03', '45.5'::float8, '', 'unbilled', 'not_required', false, 'cli',
       '{}', 'run-1', 'session-1', 'https://proof.test/1', '{"steps": {"count": 2}}', '2026-03-04 08:00:00',
       '2026-03-03 09:00:00', '2026-03-04 08:00:00'),
      (201, 2, 2, 12, 23, NULL, '2026-03-02', '60'::float8, 'Support', 'billed', 'not_required', true,
       'manual', '{}', NULL, NULL, NULL, '{}', NULL, '2026-03-02 11:00:00', '2026-03-02 12:00:00');

    INSERT INTO reservations (company_id, entry_id, invoice_id, state, disposition, operation_id, created_at,
                              invoice_operation_id)
    VALUES
      (1, 101, 501, 'committed', 'active', '0b1f8a4c-9d2e-4f7a-8c3b-5e6d7f8a9b0c', '2026-03-05 09:00:00', 1),
      (2, 201, 601, 'committed', 'retained', '1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f', '2026-03-05 10:00:00', NULL);

    INSERT INTO invoice_operations (id, company_id, invoice_id, operation_id, actor_name, state, desired_entry_ids,
                                    disposition, generation, created_at, finished_at)
    VALUES
      (1, 1, 501, '0b1f8a4c-9d2e-4f7a-8c3b-5e6d7f8a9b0c', 'monolith', 'committed', '{101}', 'active', 2,
       '2026-03-05 09:00:00', '2026-03-05 09:00:01.5'),
      (2, 2, 601, '1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f', 'monolith', 'committed', '{201}', 'retained', 2,
       '2026-03-05 10:00:00', '2026-03-05 10:00:02'),
      (3, 2, 602, '2d3e4f5a-6b7c-4d8e-9f0a-1b2c3d4e5f6a', 'billing-worker', 'aborted', '{}', 'active', 2,
       '2026-03-05 11:00:00', NULL);

    INSERT INTO entry_audits (id, company_id, entry_id, actor_type, actor_id, actor_name, action, before, after,
                              entry_created_at, created_at)
    VALUES
      (1, 1, 101, 'User', 21, NULL, 'create', 'null', '{"duration": 60, "meta": {"source": "web", "ids": [1, 2]}}',
       '2026-03-02 09:15:30.123456', '2026-03-02 09:15:30.123456'),
      (2, 1, 101, 'Agent', 31, NULL, 'update', '{"duration": 60}', '{"duration": 1.00000000000000000001}',
       '2026-03-02 09:15:30.123456', '2026-03-02 10:00:00.654321'),
      (3, 2, 201, 'service', NULL, 'billing-worker', 'create', NULL, '{"duration": 60}', '2026-03-02 11:00:00',
       '2026-03-02 11:00:00');

    INSERT INTO idempotency_records (id, company_id, actor_type, actor_id, operation, key, fingerprint, status, body,
                                     created_at)
    VALUES
      (1, 1, 'User', 21, 'create_entry', 'same-key', 'fp-1', 201, '{ "id": 101,   "note": "Design review" }',
       '2026-03-02 09:15:30.123456'),
      (2, 2, 'User', 23, 'create_entry', 'same-key', 'fp-2', 201, '{"id":201}', '2026-03-02 11:00:00');
  SQL
end
