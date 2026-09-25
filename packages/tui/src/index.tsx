import {render} from "ink";
import {App} from "./app.js";
import {CftunnelOperations} from "./operations.js";

if (process.stdout.isTTY) process.stdout.write("\u001B[2J\u001B[H");
render(<App client={new CftunnelOperations()}/>);
