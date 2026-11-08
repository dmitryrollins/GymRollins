#!/usr/bin/env node
// Prints Better Auth's tables as SQL for D1 (npm run gen:auth-schema writes migrations/0001_better_auth.sql), offline,
// from Better Auth's own schema compiler run against an empty in-memory SQLite. There is no @better-auth/cli for 1.7.
// The options here must add the same tables as createAuth's (src/auth/auth.ts); test/auth.test.ts checks the result.
import { DatabaseSync } from 'node:sqlite'
import { getMigrations } from 'better-auth/db/migration'

const { compileMigrations } = await getMigrations({
  database: new DatabaseSync(':memory:'),
  emailAndPassword: { enabled: true },
  advanced: { database: { generateId: () => crypto.randomUUID() } },
})
console.log(await compileMigrations())
