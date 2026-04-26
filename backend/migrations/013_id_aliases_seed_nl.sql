-- Migration 013: seed id_aliases with NL→DE mappings (one-shot, idempotent).
-- Generated 2026-04-25 from backups/inventory_20260425/. 31 matched + 1 race-dedup.
-- See 012_id_aliases.sql for table purpose.

-- Inline commas BEFORE the trailing -- comment, otherwise the comment
-- swallows the comma and psql sees adjacent tuples without a separator.

INSERT INTO id_aliases (alt_id, real_id, source) VALUES
  (2, 12088, 'nl_decommission'),  -- device_3ce22712 (adc20e5a-7b51-4856-9b85-80a44f55a797)
  (3, 12318, 'nl_decommission'),  -- device_75bb6aa8 (9dafceeb-58e0-4157-bfe0-427c27059f95)
  (4, 12351, 'nl_decommission'),  -- device_b6f01ebb (68ba1e44-74ab-425b-b12d-1cfae8348325)
  (1, 13824, 'nl_decommission'),  -- device_768e7174 (b6fcbb7c-9d25-43f9-afb2-531a0df9acf8)
  (170, 14337, 'nl_decommission'),  -- device_7cdf7a6a (25d3fa7e-ffe3-48bf-8223-282502b451e1)
  (1632, 15802, 'nl_decommission'),  -- device_50d5a32e (edbbf776-7da6-4c56-8834-652596b4d4f0)
  (15654, 28633, 'nl_decommission'),  -- device_2d79f39a (76f1323b-8070-4615-8072-bf584f89337e)
  (15773, 28751, 'nl_decommission'),  -- device_516daf06 (3076c8f7-b542-4b03-8b93-e725761337fb)
  (15855, 28823, 'nl_decommission'),  -- device_0e5bbae0 (dcb5671e-689c-4b87-abe6-bcfe9fa26a77)
  (15918, 28888, 'nl_decommission'),  -- device_2533c8c1 (b2989acb-f668-456e-8f59-353e6317f471)
  (16553, 29542, 'nl_decommission'),  -- device_005eec81 (a82c786d-1f2d-4079-8e18-1d6078a5a941)
  (16554, 29543, 'nl_decommission'),  -- device_77d920bf (0adf4ed4-e39c-4d29-a198-727eb10c01a3)
  (16627, 29618, 'nl_decommission'),  -- device_80ffce21 (aea7cacf-4347-4edd-bede-84f40e5122e1)
  (16689, 29681, 'nl_decommission'),  -- device_9f86d081 (d7fd6ad8-f095-48ba-9791-cf3c95880de0)
  (16806, 29797, 'nl_decommission'),  -- device_24384810 (44b69c9a-c902-414e-82f2-dc605e0cd1bb)
  (16818, 29810, 'nl_decommission'),  -- device_6221c006 (da8ce5cd-2920-4a86-bb2c-420bf4fe5135)
  (19288, 32326, 'nl_decommission'),  -- device_d87a6df5 (633b09b2-e7e1-45ba-b4f2-34bc5cf9dcac)
  (21546, 34524, 'nl_decommission'),  -- device_6373067f (f5fadc4c-05cb-4390-b74a-15788f95c9a9)
  (23814, 36772, 'nl_decommission'),  -- device_c165a3e1 (44a4059b-8e5d-40d5-8c7c-5b6f4f1cf469)
  (24103, 37041, 'nl_decommission'),  -- device_5d21d369 (52d84a1a-85f3-4c01-8141-d81dd24ba7a8)
  (24666, 37617, 'nl_decommission'),  -- device_243021af (24243d14-72fc-4c11-9d9f-c6efc2133686)
  (32895, 45959, 'nl_decommission'),  -- device_33571d58 (a9dcbf09-c171-451f-aff3-d3d3833d431d)
  (32943, 46006, 'nl_decommission'),  -- device_692901ca (536b7de4-aa59-4e41-91cc-1309763e5812)
  (32967, 46032, 'nl_decommission'),  -- device_a2c8d661 (cec1e0f0-38a2-41aa-8530-498460f130b2)
  (32970, 46033, 'nl_decommission'),  -- device_07cd3e52 (d50ce087-ee9b-443c-b845-77ee32fecbca)
  (32971, 46034, 'nl_decommission'),  -- device_8963ddc5 (47f18549-44a0-40e5-bf8a-651211892ed3)
  (32972, 46035, 'nl_decommission'),  -- device_2b255a2e (200a8faf-2387-4b2a-a092-d6c94073c743)
  (33027, 46089, 'nl_decommission'),  -- device_71384412 (c6f77950-c8b8-4526-96bb-0e8380201a6d)
  (33028, 46090, 'nl_decommission'),  -- device_5018048c (caf2fd22-2f62-4850-9e03-5d6e5b73e47b)
  (33029, 46091, 'nl_decommission'),  -- device_e930e053 (288c48ba-dcea-46e0-9012-4598a1820766)
  (33125, 46187, 'nl_decommission')   -- device_c5909650 (687addd4-4bf7-4535-9aaa-daed0555bf99)
ON CONFLICT (alt_id) DO NOTHING;

-- Race-dedup: device_5b1fac69 was registered twice on the same second on
-- different nodes (DE id=32446 ec7a2b8d, NL id=19376 245aeec7). Both
-- anonymous, no subscription. Alias NL id 19376 → DE 32446.
INSERT INTO id_aliases (alt_id, real_id, source) VALUES (19376, 32446, 'race_dedup')
ON CONFLICT (alt_id) DO NOTHING;
