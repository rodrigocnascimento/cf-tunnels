import {render} from "ink";
import {App} from "./app.js";
import {CftunnelOperations} from "./operations.js";

const client = new CftunnelOperations();
const binary = process.env.CFTUNNEL_BIN ?? "cftunnel";
let instance: ReturnType<typeof render>;

const clearScreen = () => {
	if (process.stdout.isTTY) process.stdout.write("\u001B[2J\u001B[H");
};

const start = () => {
	clearScreen();
	instance = render(<App client={client} onLogin={runLogin}/>);
};

const runLogin = async (zone: string) => {
	instance.unmount();
	clearScreen();
	const child = Bun.spawn([binary, "--zone", zone, "zone", "login"], {stdin: "inherit", stdout: "inherit", stderr: "inherit"});
	await child.exited;
	start();
};

start();
