// In-memory stand-ins for the Prisma tables the push service uses, so its tests never touch a database. Only the
// queries push.ts makes: equality and { in: [...] } filters, select, upsert by a unique field, deleteMany.

type Row = Record<string, unknown>;

const matches = (row: Row, where: Row = {}) =>
  Object.entries(where).every(([k, v]) =>
    v !== null && typeof v === 'object' && 'in' in (v as Row) ? (v as { in: unknown[] }).in.includes(row[k]) : row[k] === v);

const pick = (row: Row, select?: Record<string, boolean>) =>
  select ? Object.fromEntries(Object.keys(select).map((k) => [k, row[k]])) : { ...row };

/** autoId: numbers new rows 1, 2, 3… like an AUTO_INCREMENT id */
export function fakeTable(rows: Row[], { autoId = false } = {}) {
  let nextId = 1;
  const insert = (data: Row) => {
    const row = { ...(autoId ? { id: nextId++ } : {}), ...data };
    rows.push(row);
    return { ...row };
  };
  return {
    rows,
    findMany: async ({ where, select }: { where?: Row; select?: Record<string, boolean> } = {}) => rows.filter((r) => matches(r, where)).map((r) => pick(r, select)),
    findUnique: async ({ where }: { where: Row }) => {
      const r = rows.find((x) => matches(x, where));
      return r ? { ...r } : null;
    },
    create: async ({ data }: { data: Row }) => insert(data),
    upsert: async ({ where, create, update }: { where: Row; create: Row; update: Row }) => {
      const r = rows.find((x) => matches(x, where));
      if (!r) return insert(create);
      Object.assign(r, update);
      return { ...r };
    },
    deleteMany: async ({ where }: { where: Row }) => {
      const before = rows.length;
      for (let i = rows.length - 1; i >= 0; i--) if (matches(rows[i], where)) rows.splice(i, 1);
      return { count: before - rows.length };
    },
  };
}
