import Foundation

/// A document-scoped WebMCP compatibility subset for WebKit. It exposes no native
/// message handlers. Facet separately confirms every invocation in native UI.
enum QuartzWebMCPScript {
    static let snapshotScript = "return await globalThis.__quartzWebMCP?.snapshot() ?? null;"
    static let executeScript = "return await globalThis.__quartzWebMCP.execute(toolID, input, documentID);"
    static let cancelScript = "return globalThis.__quartzWebMCP?.cancel(documentID) ?? false;"

    static let source = #"""
    (() => {
        'use strict';
        if (window !== window.top || !globalThis.isSecureContext ||
            !['https:', 'http:'].includes(location.protocol) || location.origin === 'null' ||
            Object.prototype.hasOwnProperty.call(globalThis, '__quartzWebMCP')) return;
        if (location.protocol === 'http:' && !(location.hostname === 'localhost' ||
            location.hostname.endsWith('.localhost') || location.hostname === '[::1]' ||
            location.hostname === '127.0.0.1')) return;
        const policy = document.permissionsPolicy || document.featurePolicy;
        if (policy && typeof policy.features === 'function' && policy.features().includes('tools') &&
            !policy.allowsFeature('tools')) return;

        const stringify = JSON.stringify.bind(JSON), parse = JSON.parse.bind(JSON);
        const freeze = Object.freeze.bind(Object), keys = Object.keys.bind(Object);
        const define = Object.defineProperty.bind(Object), create = Object.create.bind(Object);
        const own = Function.call.bind(Object.prototype.hasOwnProperty);
        const apply = Reflect.apply.bind(Reflect);
        const timeout = setTimeout.bind(window), untimer = clearTimeout.bind(window);
        const NativePromise = Promise, NativeError = DOMException, NativeEvent = Event, NativeTypeError = TypeError;
        const NativeAbortController = AbortController, NativeAbortSignal = AbortSignal, NativeCustomEvent = CustomEvent;
        const origin = location.origin;
        const documentID = crypto.randomUUID();
        const LIMIT = freeze({tools: 64, schema: 65536, input: 65536, result: 262144, timeout: 30000});
        let serial = 0, alive = true;
        const records = new Map(), names = new Map(), descriptors = new WeakMap();
        const active = new Map(), formRecords = new Map(), activeForms = new Map();
        const nativeContext = document.modelContext || navigator.modelContext;
        const error = (message, name = 'InvalidStateError') => name === 'TypeError' ? new NativeTypeError(message) : new NativeError(message, name);
        const freshID = () => documentID + ':' + (++serial);
        function json(value, limit, label) {
            let text;
            try { text = stringify(value); } catch { throw error(label + ' must be JSON serializable.', 'DataError'); }
            if (typeof text !== 'string') throw error(label + ' must be JSON serializable.', 'DataError');
            if (text.length > limit) throw error(label + ' exceeds the size limit.', 'QuotaExceededError');
            return text;
        }
        function clone(value, limit, label) { return parse(json(value, limit, label)); }
        function checkAlive() {
            if (!alive || location.origin !== origin) throw error('The WebMCP document is no longer active.');
        }
        function localOrigins(options, key) {
            if (!options || options[key] === undefined) return;
            if (!Array.isArray(options[key]) || options[key].some(value => value !== origin))
                throw error('Quartz supports WebMCP tools only in the current document and origin.', 'NotSupportedError');
        }
        function deepFreeze(value) {
            if (value && typeof value === 'object') { for (const key of keys(value)) deepFreeze(value[key]); freeze(value); }
            return value;
        }
        const schemaKeywords = new Set(['type', 'properties', 'required', 'additionalProperties', 'items',
            'enum', 'const', 'anyOf', 'oneOf', 'allOf', 'not', 'minimum', 'maximum', 'exclusiveMinimum',
            'exclusiveMaximum', 'multipleOf', 'minLength', 'maxLength', 'minItems', 'maxItems', 'uniqueItems',
            'minProperties', 'maxProperties', 'title', 'description', 'default', 'examples', '$schema', '$id',
            '$comment', 'readOnly', 'writeOnly', 'deprecated']);
        const types = new Set(['object', 'array', 'string', 'number', 'integer', 'boolean', 'null']);
        function inspectSchema(schema, depth = 0, budget = {nodes: 0}) {
            if (typeof schema === 'boolean') return;
            if (!schema || typeof schema !== 'object' || Array.isArray(schema)) throw error('Invalid JSON Schema.', 'TypeError');
            if (depth > 16 || ++budget.nodes > 512) throw error('JSON Schema is too complex.', 'QuotaExceededError');
            for (const key of keys(schema)) {
                if (!schemaKeywords.has(key)) throw error('Unsupported JSON Schema keyword: ' + key, 'NotSupportedError');
            }
            if (schema.type !== undefined) {
                const values = Array.isArray(schema.type) ? schema.type : [schema.type];
                if (!values.length || values.some(value => !types.has(value))) throw error('Invalid schema type.', 'TypeError');
            }
            if (schema.properties !== undefined) {
                if (!schema.properties || typeof schema.properties !== 'object' || Array.isArray(schema.properties))
                    throw error('Schema properties must be an object.', 'TypeError');
                for (const key of keys(schema.properties)) inspectSchema(schema.properties[key], depth + 1, budget);
            }
            if (schema.required !== undefined && (!Array.isArray(schema.required) || schema.required.some(key => typeof key !== 'string')))
                throw error('Schema required must contain property names.', 'TypeError');
            for (const key of ['items', 'additionalProperties', 'not']) {
                if (schema[key] !== undefined) inspectSchema(schema[key], depth + 1, budget);
            }
            for (const key of ['anyOf', 'oneOf', 'allOf']) {
                if (schema[key] !== undefined) {
                    if (!Array.isArray(schema[key]) || !schema[key].length) throw error('Invalid schema ' + key, 'TypeError');
                    for (const child of schema[key]) inspectSchema(child, depth + 1, budget);
                }
            }
            if (schema.enum !== undefined && (!Array.isArray(schema.enum) || !schema.enum.length)) throw error('Invalid schema enum.', 'TypeError');
            for (const key of ['minLength', 'maxLength', 'minItems', 'maxItems', 'minProperties', 'maxProperties']) {
                if (schema[key] !== undefined && (!Number.isInteger(schema[key]) || schema[key] < 0)) throw error('Invalid schema ' + key, 'TypeError');
            }
            for (const key of ['minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf']) {
                if (schema[key] !== undefined && (typeof schema[key] !== 'number' || !Number.isFinite(schema[key]) ||
                    (key === 'multipleOf' && schema[key] <= 0))) throw error('Invalid schema ' + key, 'TypeError');
            }
            if (schema.uniqueItems !== undefined && typeof schema.uniqueItems !== 'boolean') throw error('Invalid uniqueItems.', 'TypeError');
        }
        function equal(a, b) {
            if (a === b) return true;
            if (!a || !b || typeof a !== 'object' || typeof b !== 'object' || Array.isArray(a) !== Array.isArray(b)) return false;
            const ak = keys(a), bk = keys(b);
            return ak.length === bk.length && ak.every(key => own(b, key) && equal(a[key], b[key]));
        }
        function valid(value, schema, depth = 0) {
            if (schema === true) return true;
            if (schema === false || depth > 32) return false;
            if (schema.type !== undefined) {
                const allowed = Array.isArray(schema.type) ? schema.type : [schema.type];
                const matches = allowed.some(type => type === 'null' ? value === null :
                    type === 'array' ? Array.isArray(value) : type === 'object' ? value !== null && typeof value === 'object' && !Array.isArray(value) :
                    type === 'integer' ? Number.isInteger(value) : typeof value === type);
                if (!matches) return false;
            }
            if (schema.enum && !schema.enum.some(item => equal(item, value))) return false;
            if (own(schema, 'const') && !equal(schema.const, value)) return false;
            if (schema.anyOf && !schema.anyOf.some(child => valid(value, child, depth + 1))) return false;
            if (schema.oneOf && schema.oneOf.filter(child => valid(value, child, depth + 1)).length !== 1) return false;
            if (schema.allOf && !schema.allOf.every(child => valid(value, child, depth + 1))) return false;
            if (schema.not && valid(value, schema.not, depth + 1)) return false;
            if (typeof value === 'number') {
                if ((schema.minimum !== undefined && value < schema.minimum) || (schema.maximum !== undefined && value > schema.maximum) ||
                    (schema.exclusiveMinimum !== undefined && value <= schema.exclusiveMinimum) ||
                    (schema.exclusiveMaximum !== undefined && value >= schema.exclusiveMaximum)) return false;
                if (schema.multipleOf !== undefined && Math.abs(value / schema.multipleOf - Math.round(value / schema.multipleOf)) > 1e-9) return false;
            }
            if (typeof value === 'string') {
                const length = [...value].length;
                if ((schema.minLength !== undefined && length < schema.minLength) || (schema.maxLength !== undefined && length > schema.maxLength)) return false;
            }
            if (Array.isArray(value)) {
                if ((schema.minItems !== undefined && value.length < schema.minItems) || (schema.maxItems !== undefined && value.length > schema.maxItems)) return false;
                if (schema.items !== undefined && !value.every(item => valid(item, schema.items, depth + 1))) return false;
                if (schema.uniqueItems && value.some((item, index) => value.slice(0, index).some(other => equal(item, other)))) return false;
            } else if (value !== null && typeof value === 'object') {
                const properties = schema.properties || create(null), count = keys(value).length;
                if ((schema.minProperties !== undefined && count < schema.minProperties) || (schema.maxProperties !== undefined && count > schema.maxProperties)) return false;
                if (schema.required && !schema.required.every(key => own(value, key))) return false;
                for (const key of keys(value)) {
                    if (own(properties, key)) { if (!valid(value[key], properties[key], depth + 1)) return false; }
                    else if (schema.additionalProperties === false || (schema.additionalProperties && !valid(value[key], schema.additionalProperties, depth + 1))) return false;
                }
            }
            return true;
        }
        function metadata(record) {
            return {id: record.id, name: record.name, description: record.description,
                inputSchema: record.inputSchema, ...(record.title ? {title: record.title} : {}),
                annotations: record.annotations, source: record.source};
        }
        function announce() { context.dispatchEvent(new NativeEvent('toolchange')); }
        function remove(record) {
            if (records.get(record.id) !== record) return;
            records.delete(record.id);
            if (names.get(record.name) === record) names.delete(record.name);
            if (record.cleanup) record.cleanup();
            for (const entry of active.values()) if (entry.record === record) entry.controller.abort(error('The tool was unregistered.', 'AbortError'));
            announce();
        }
        function prepare(tool, source) {
            if (!tool || typeof tool !== 'object' || typeof tool.name !== 'string' || !/^[A-Za-z0-9_.-]{1,128}$/.test(tool.name))
                throw error('Tool names must contain 1–128 letters, digits, underscores, periods, or hyphens.');
            if (typeof tool.description !== 'string' || !tool.description.trim() || tool.description.length > 8192)
                throw error('A tool needs a nonempty description of at most 8192 characters.');
            if (typeof tool.execute !== 'function') throw error('Tool execute must be a function.', 'TypeError');
            const schema = clone(tool.inputSchema === undefined ? {type: 'object'} : tool.inputSchema, LIMIT.schema, 'Tool schema');
            inspectSchema(schema);
            if (!schema || typeof schema !== 'object' || Array.isArray(schema) || (schema.type !== undefined && schema.type !== 'object'))
                throw error('Tool inputSchema must describe an object.', 'TypeError');
            const annotations = {};
            for (const key of ['readOnlyHint', 'untrustedContentHint', 'consequentialHint']) annotations[key] = tool.annotations?.[key] === true;
            return {id: freshID(), name: tool.name, description: tool.description, inputSchema: deepFreeze(schema),
                title: typeof tool.title === 'string' ? tool.title.slice(0, 256) : undefined,
                annotations: freeze(annotations), execute: tool.execute, source};
        }
        function add(record) {
            if (names.has(record.name)) throw error('A tool with this name is already registered.');
            if (records.size >= LIMIT.tools) throw error('Too many WebMCP tools.', 'QuotaExceededError');
            records.set(record.id, record); names.set(record.name, record); announce();
        }
        async function run(record, input, signal) {
            checkAlive();
            syncForms();
            if (records.get(record.id) !== record) throw error('This WebMCP tool registration is stale.', 'NotFoundError');
            if (signal?.aborted) throw error('Tool execution was canceled.', 'AbortError');
            if (!input || typeof input !== 'object' || Array.isArray(input)) throw error('Tool input must be an object.', 'TypeError');
            const argumentsCopy = clone(input, LIMIT.input, 'Tool input');
            if (!valid(argumentsCopy, record.inputSchema)) throw error('Tool input does not match its JSON Schema.', 'TypeError');
            const controller = new NativeAbortController(), token = freshID();
            const forwardAbort = () => controller.abort(error('Tool execution was canceled.', 'AbortError'));
            signal?.addEventListener('abort', forwardAbort, {once: true});
            active.set(token, {record, controller});
            const timer = timeout(() => controller.abort(error('WebMCP tool timed out after 30 seconds.', 'TimeoutError')), LIMIT.timeout);
            let rejectAbort;
            const aborted = new NativePromise((resolve, reject) => { rejectAbort = () => reject(controller.signal.reason || error('Tool execution was canceled.', 'AbortError')); });
            controller.signal.addEventListener('abort', rejectAbort, {once: true});
            try {
                const value = await NativePromise.race([
                    NativePromise.resolve().then(() => { controller.signal.throwIfAborted(); return apply(record.execute, undefined, [argumentsCopy, {signal: controller.signal}]); }), aborted
                ]);
                checkAlive();
                if (records.get(record.id) !== record) throw error('The tool registration changed during execution.');
                return json(value, LIMIT.result, 'Tool result');
            } finally {
                untimer(timer); active.delete(token);
                controller.signal.removeEventListener('abort', rejectAbort);
                signal?.removeEventListener('abort', forwardAbort);
            }
        }

        // Declarative HTML is an experimental subset. Navigation results and engine
        // CSS pseudo classes cannot be provided by a page compatibility script.
        function formDefinition(form) {
            const name = form.getAttribute('toolname'), description = form.getAttribute('tooldescription');
            if (!name || !description || !form.isConnected) return null;
            const groups = new Map(), properties = create(null), required = [];
            const controls = [...form.elements];
            if (controls.length > 128) return null;
            for (const control of controls) {
                if (!(control instanceof HTMLInputElement || control instanceof HTMLSelectElement || control instanceof HTMLTextAreaElement) ||
                    control.matches(':disabled') || !control.name || ['submit', 'reset', 'button', 'image'].includes(control.type)) continue;
                if (control.type === 'file') return null;
                const group = groups.get(control.name) || []; group.push(control); groups.set(control.name, group);
            }
            for (const [key, group] of groups) {
                const control = group[0], type = control.type;
                let schema = {type: 'string'};
                if (group.length > 1 && !['radio', 'checkbox'].includes(type)) return null;
                if (group.some(item => item.type !== type)) return null;
                if (type === 'checkbox') schema = group.length === 1 ? {type: 'boolean'} : {type: 'array', items: {type: 'string', enum: group.map(item => item.value)}, uniqueItems: true};
                else if (type === 'radio') schema = {type: 'string', enum: group.map(item => item.value)};
                else if (control instanceof HTMLSelectElement) {
                    const options = [...control.options].filter(option => !option.disabled && !option.closest('optgroup[disabled]'));
                    const choices = {type: 'string', enum: options.map(option => option.value), anyOf: options.map(option => ({const: option.value, title: option.textContent.trim()}))};
                    if (!options.length) return null;
                    schema = control.multiple ? {type: 'array', items: choices, uniqueItems: true} : choices;
                } else if (type === 'number' || type === 'range') {
                    schema = {type: control.step !== 'any' && Number.isInteger(Number(control.step || 1)) &&
                        (control.min === '' || Number.isInteger(Number(control.min))) ? 'integer' : 'number'};
                    if (control.min !== '' && Number.isFinite(Number(control.min))) schema.minimum = Number(control.min);
                    if (control.max !== '' && Number.isFinite(Number(control.max))) schema.maximum = Number(control.max);
                } else {
                    if (control.minLength >= 0) schema.minLength = control.minLength;
                    if (control.maxLength >= 0) schema.maxLength = control.maxLength;
                }
                const explanation = control.getAttribute('toolparamdescription') || [...(control.labels || [])].map(label => label.textContent.trim()).join(' ') || control.getAttribute('aria-description');
                if (explanation) schema.description = explanation.slice(0, 4096);
                if (group.some(item => item.required)) required.push(key);
                if (type === 'checkbox' && group.length === 1 && control.required) schema.const = true;
                properties[key] = schema;
            }
            const inputSchema = {type: 'object', properties, required, additionalProperties: false};
            const signature = json({name, description, inputSchema, autosubmit: form.hasAttribute('toolautosubmit'),
                action: form.action, method: form.method}, LIMIT.schema, 'Form schema');
            return {name, description, inputSchema, signature, groups};
        }
        function toolEvent(target, name, toolName) {
            const event = new NativeCustomEvent(name, {detail: {toolName}});
            define(event, 'toolName', {value: toolName}); target.dispatchEvent(event);
        }
        function cancelForm(form, state, reason) {
            if (activeForms.get(form) !== state) return;
            state.reject(reason || error('Form tool was canceled.', 'AbortError'));
            toolEvent(window, 'toolcancel', state.record.name);
            toolEvent(context, 'toolcanceled', state.record.name);
        }
        function executeForm(form, record, input, {signal}) {
            if (activeForms.has(form)) throw error('This form tool is already running.');
            const definition = formDefinition(form);
            if (!definition || definition.signature !== record.signature) throw error('Form tool changed before execution.');
            return new NativePromise((resolve, reject) => {
                const state = {record, resolve, reject, submitted: false, responded: false};
                activeForms.set(form, state);
                const abort = () => cancelForm(form, state, signal.reason);
                const reset = () => cancelForm(form, state);
                signal.addEventListener('abort', abort, {once: true});
                form.addEventListener('reset', reset);
                const cleanup = () => {
                    if (activeForms.get(form) === state) activeForms.delete(form);
                    form.removeAttribute('data-quartz-tool-active');
                    signal.removeEventListener('abort', abort); form.removeEventListener('reset', reset);
                };
                state.resolve = value => { cleanup(); resolve(value); };
                state.reject = reason => { cleanup(); reject(reason); };
                try {
                    for (const [key, group] of definition.groups) {
                        if (!own(input, key)) continue;
                        for (const control of group) {
                            if (control.type === 'checkbox') control.checked = group.length === 1 ? input[key] : input[key].includes(control.value);
                            else if (control.type === 'radio') control.checked = input[key] === control.value;
                            else if (control instanceof HTMLSelectElement && control.multiple) {
                                for (const option of control.options) option.selected = input[key].includes(option.value);
                            } else control.value = String(input[key]);
                            control.dispatchEvent(new NativeEvent('input', {bubbles: true}));
                            control.dispatchEvent(new NativeEvent('change', {bubbles: true}));
                        }
                    }
                    signal.throwIfAborted();
                    if (!form.checkValidity()) throw error('The filled form does not pass HTML validation.', 'TypeError');
                    form.setAttribute('data-quartz-tool-active', '');
                    toolEvent(window, 'toolactivated', record.name);
                    if (form.hasAttribute('toolautosubmit')) HTMLFormElement.prototype.requestSubmit.call(form);
                    else (form.querySelector('button:not([type]),button[type="submit"],input[type="submit"]') || form).focus();
                } catch (reason) { state.reject(reason); }
            });
        }
        let syncing = false;
        function syncForms() {
            if (nativeContext || syncing || !alive) return;
            syncing = true;
            try {
                const seen = new Set();
                for (const form of [...document.querySelectorAll('form[toolname][tooldescription]')].slice(0, LIMIT.tools)) {
                    seen.add(form);
                    let definition;
                    try { definition = formDefinition(form); } catch { definition = null; }
                    let previous = formRecords.get(form);
                    if (previous && (!definition || definition.signature !== previous.signature)) {
                        remove(previous); formRecords.delete(form); previous = null;
                    }
                    if (!definition || previous || names.has(definition.name) || records.size >= LIMIT.tools) continue;
                    try {
                        let record;
                        record = prepare({...definition, execute: (input, context) => executeForm(form, record, input, context)}, 'declarative');
                        record.signature = definition.signature; add(record); formRecords.set(form, record);
                    } catch { /* Invalid declarations are not advertised as executable tools. */ }
                }
                for (const [form, record] of formRecords) {
                    if (!seen.has(form)) { remove(record); formRecords.delete(form); }
                }
            } finally { syncing = false; }
        }
        class QuartzModelContext extends EventTarget {
            async registerTool(tool, options = {}) {
                checkAlive(); localOrigins(options, 'exposedTo');
                if (options.signal !== undefined && !(options.signal instanceof NativeAbortSignal)) throw error('signal must be an AbortSignal.', 'TypeError');
                if (options.signal?.aborted) throw error('Tool registration was canceled.', 'AbortError');
                syncForms();
                const record = prepare(tool, 'imperative');
                if (options.signal) {
                    const unregister = () => remove(record);
                    options.signal.addEventListener('abort', unregister, {once: true});
                    record.cleanup = () => options.signal.removeEventListener('abort', unregister);
                }
                try { add(record); } catch (reason) { record.cleanup?.(); throw reason; }
            }
            async getTools(options = {}) {
                checkAlive(); localOrigins(options, 'fromOrigins'); syncForms();
                return [...records.values()].map(record => {
                    const descriptor = freeze({name: record.name, description: record.description, inputSchema: record.inputSchema,
                        ...(record.title ? {title: record.title} : {}), annotations: record.annotations, window, origin});
                    descriptors.set(descriptor, record); return descriptor;
                });
            }
            async executeTool(tool, input, options = {}) {
                if (options.signal !== undefined && !(options.signal instanceof NativeAbortSignal)) throw error('signal must be an AbortSignal.', 'TypeError');
                const record = descriptors.get(tool);
                if (!record) throw error('Use a RegisteredTool returned by getTools().', 'NotFoundError');
                return run(record, input, options.signal);
            }
            unregisterTool(name) { checkAlive(); const record = names.get(String(name)); if (record?.source === 'imperative') remove(record); }
            async provideContext(value) {
                checkAlive(); syncForms();
                if (!value || !Array.isArray(value.tools)) throw error('Context tools must be an array.', 'TypeError');
                // Validate the replacement before clearing the current context.
                const prepared = value.tools.map(tool => prepare(tool, 'imperative'));
                const proposed = new Set();
                for (const record of prepared) {
                    if (proposed.has(record.name) || names.get(record.name)?.source === 'declarative') throw error('Duplicate tool name.');
                    proposed.add(record.name);
                }
                if (prepared.length + formRecords.size > LIMIT.tools) throw error('Too many WebMCP tools.', 'QuotaExceededError');
                this.clearContext(); for (const record of prepared) add(record);
            }
            clearContext() { checkAlive(); for (const record of [...records.values()]) if (record.source === 'imperative') remove(record); }
        }
        const context = nativeContext || new QuartzModelContext();
        if (!nativeContext) {
            let handler = null;
            define(context, 'ontoolchange', {enumerable: true, get: () => handler, set(value) {
                if (handler) context.removeEventListener('toolchange', handler);
                handler = typeof value === 'function' ? value : null;
                if (handler) context.addEventListener('toolchange', handler);
            }});
            define(document, 'modelContext', {value: context, enumerable: true, configurable: false});
            if (!('modelContext' in navigator)) define(navigator, 'modelContext', {value: context, enumerable: true, configurable: false});
            document.addEventListener('submit', event => {
                const form = event.target, state = activeForms.get(form);
                if (!state || state.submitted) return;
                state.submitted = true;
                define(event, 'agentInvoked', {value: true});
                define(event, 'respondWith', {value(value) {
                    if (!event.defaultPrevented) throw error('Call preventDefault() before respondWith().');
                    if (state.responded) throw error('respondWith() may only be called once.');
                    state.responded = true;
                    NativePromise.resolve(value).then(state.resolve, state.reject);
                }});
                // After page handlers run, fail explicitly if they did not supply a
                // result. Ordinary browser navigation still proceeds when allowed.
                timeout(() => {
                    if (!state.responded) state.reject(error('Form handler must call preventDefault() and respondWith(); navigation results are not supported.', 'NotSupportedError'));
                }, 0);
            }, true);
            new MutationObserver(syncForms).observe(document, {subtree: true, childList: true, attributes: true,
                attributeFilter: ['toolname', 'tooldescription', 'toolautosubmit', 'toolparamdescription', 'name', 'type',
                    'required', 'disabled', 'multiple', 'min', 'max', 'step', 'minlength', 'maxlength', 'action', 'method', 'label']});
            document.addEventListener('DOMContentLoaded', syncForms, {once: true});
        }
        const nativeTools = new Map();
        let nativeRevision = 0;
        if (nativeContext && typeof nativeContext.addEventListener === 'function') {
            nativeContext.addEventListener('toolchange', () => {
                nativeRevision++; nativeTools.clear();
                for (const entry of active.values()) entry.controller.abort(error('Native tool registrations changed.', 'AbortError'));
            });
        }
        async function snapshot() {
            checkAlive();
            if (!nativeContext) { syncForms(); return {documentID, mode: 'compatibility', tools: [...records.values()].map(metadata)}; }
            if (typeof nativeContext.getTools !== 'function' || typeof nativeContext.executeTool !== 'function')
                return {documentID, mode: 'native-unavailable', tools: []};
            const revision = nativeRevision;
            const discovered = await nativeContext.getTools();
            checkAlive();
            if (revision !== nativeRevision) throw error('Native tool registrations changed during discovery.');
            const next = new Map(), tools = [];
            for (const descriptor of discovered.slice(0, LIMIT.tools)) {
                if (descriptor.origin !== origin || descriptor.window !== window) continue;
                const value = clone({name: descriptor.name, description: descriptor.description,
                    inputSchema: descriptor.inputSchema || {type: 'object'}, title: descriptor.title,
                    annotations: descriptor.annotations || {}, source: 'native'}, LIMIT.schema, 'Native tool');
                const signature = stringify(value);
                const previous = nativeTools.get(value.name);
                const record = previous && previous.signature === signature ? previous : {id: freshID(), signature};
                record.descriptor = descriptor; next.set(value.name, record); tools.push({...value, id: record.id});
            }
            nativeTools.clear(); for (const [name, value] of next) nativeTools.set(name, value);
            return {documentID, mode: 'native', tools};
        }
        async function execute(id, input, expectedDocumentID) {
            checkAlive();
            if (expectedDocumentID !== documentID) throw error('The WebMCP document changed.', 'NotFoundError');
            if (!nativeContext) {
                const record = records.get(id);
                if (!record) throw error('The WebMCP tool is no longer registered.', 'NotFoundError');
                return run(record, input);
            }
            const record = [...nativeTools.values()].find(record => record.id === id);
            if (!record) throw error('The native WebMCP tool is no longer registered.', 'NotFoundError');
            const controller = new NativeAbortController(), token = freshID();
            active.set(token, {record, controller});
            const timer = timeout(() => controller.abort(error('WebMCP tool timed out after 30 seconds.', 'TimeoutError')), LIMIT.timeout);
            let rejectAbort;
            const aborted = new NativePromise((resolve, reject) => { rejectAbort = () => reject(controller.signal.reason || error('Tool execution was canceled.', 'AbortError')); });
            controller.signal.addEventListener('abort', rejectAbort, {once: true});
            try {
                const result = await NativePromise.race([nativeContext.executeTool(record.descriptor, clone(input, LIMIT.input, 'Tool input'), {signal: controller.signal}), aborted]);
                checkAlive();
                if (typeof result !== 'string' || result.length > LIMIT.result) throw error('Native tool returned an invalid or oversized result.', 'DataError');
                parse(result); return result;
            } finally { untimer(timer); active.delete(token); controller.signal.removeEventListener('abort', rejectAbort); }
        }
        function cancel(expectedDocumentID) {
            if (expectedDocumentID !== documentID) return false;
            for (const entry of active.values()) entry.controller.abort(error('Tool execution was canceled.', 'AbortError'));
            return true;
        }
        define(globalThis, '__quartzWebMCP', {value: freeze({snapshot, execute, cancel}), configurable: false, writable: false});
        window.addEventListener('pagehide', () => { alive = false; cancel(documentID); nativeTools.clear(); });
        window.addEventListener('pageshow', event => { if (event.persisted) { alive = true; syncForms(); } });
    })();
    """#
}
