// chi web's JSON as notifications.js and push_devices.js call it:
// (method, path, body). Over the page's api (data.js), so a signed-out
// proxy answer (a 401, a redirect, HTML) reports auth_lost as every other
// read does, and a refusal throws api()'s Error (the server's words, .status,
// .code).

import { api as pageApi } from "./data.js";

// @param body the JSON body (undefined: none)
// @param opts api()'s fetch options (specs: fetchImpl); api: another client
// @return a Promise of the answer's JSON ({} for an empty one)
export function methodApi(method, path, body, { api = pageApi, ...opts } = {}) {
  return api(path, { ...opts, method, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
}
