const [path, maximumInput] = Deno.args;
if (path === undefined || maximumInput === undefined) {
  throw new Error("Usage: check_artifact_size.ts <artifact> <maximum-bytes>");
}

const maximum = Number(maximumInput);
if (!Number.isSafeInteger(maximum) || maximum <= 0) {
  throw new Error(`Invalid maximum size: ${maximumInput}`);
}

const size = await measurePath(path);

const mebibytes = size / 1024 / 1024;
console.log(`${path}: ${size} bytes (${mebibytes.toFixed(2)} MiB)`);
if (size > maximum) {
  throw new Error(`Artifact exceeds the ${maximum}-byte size budget.`);
}

async function measurePath(path: string): Promise<number> {
  const stat = await Deno.lstat(path);
  if (!stat.isDirectory) return stat.size;

  let total = 0;
  for await (const entry of Deno.readDir(path)) {
    total += await measurePath(`${path}/${entry.name}`);
  }
  return total;
}
