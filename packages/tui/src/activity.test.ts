import {expect, test} from "bun:test";
import {activityDetails} from "./activity.js";

test("activity details preserve useful diagnostics while redacting credentials", () => {
	const details = activityDetails("error: discovery failed\ntoken=secret-value\n{\"authorization\":\"secret-json\"}\nBearer abc.def\n-----BEGIN ARGO TUNNEL TOKEN-----\nvery-secret\n-----END ARGO TUNNEL TOKEN-----");
	expect(details).toContain("error: discovery failed");
	expect(details.join("\n")).not.toContain("secret-value");
	expect(details.join("\n")).not.toContain("secret-json");
	expect(details.join("\n")).not.toContain("very-secret");
	expect(details.join("\n")).not.toContain("abc.def");
});
