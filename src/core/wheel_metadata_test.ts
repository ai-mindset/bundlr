import { assertEquals } from "jsr:@std/assert@1.0.19";
import { parseWheelRequirements } from "./wheel_metadata.ts";

Deno.test("reads repeated and folded wheel requirements", () => {
  assertEquals(
    parseWheelRequirements(
      "Metadata-Version: 2.4\n" +
        "Name: example\n" +
        "Requires-Dist: click>=8\n" +
        "Requires-Dist: colorama>=0.4;\n  sys_platform == 'win32'\n\nDescription\n",
    ),
    ["click>=8", "colorama>=0.4;sys_platform == 'win32'"],
  );
});

Deno.test("returns no requirements when metadata has none", () => {
  assertEquals(parseWheelRequirements("Metadata-Version: 2.4\nName: example\n"), []);
});
