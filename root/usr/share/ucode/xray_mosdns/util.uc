// luci-app-xray-mosdns-x - shared helpers
'use strict';

export function fail(msg) {
	warn(`ERROR: ${msg}\n`);
	system([ 'logger', '-t', 'xray-mosdns-gen', `ERROR: ${msg}` ]);
	exit(1);
};

export function note(msg) {
	warn(`${msg}\n`);
	system([ 'logger', '-t', 'xray-mosdns-gen', msg ]);
};

export function bool(v, dflt) {
	if (v == null || v === '')
		return !!dflt;
	return (v === '1' || v === 'true' || v === 'on' || v === 'yes' || v === true || v === 1);
};

export function str(v, dflt) {
	if (v == null)
		return dflt;
	v = trim(`${v}`);
	return length(v) ? v : dflt;
};

export function port(v, dflt, what) {
	v = str(v, null);
	if (v == null)
		return dflt;
	if (!match(v, /^[0-9]+$/) || +v < 1 || +v > 65535)
		fail(`invalid port for ${what}: '${v}'`);
	return +v;
};

// uci list (array) or whitespace separated string -> array of non-empty strings
export function list(v) {
	let out = [];
	if (v == null)
		return out;
	if (type(v) != 'array')
		v = [ v ];
	for (let item in v) {
		item = trim(`${item}`);
		if (length(item))
			push(out, item);
	}
	return out;
};

export function words(v) {
	let out = [];
	for (let item in list(v))
		for (let w in split(item, /[ \t,]+/))
			if (length(w))
				push(out, w);
	return out;
};

const RE_V4 = /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(\/([0-9]{1,2}))?$/;
const RE_V6 = /^[0-9a-fA-F:]+(\/[0-9]{1,3})?$/;

// returns 4, 6 or 0 for "address or CIDR" literals
export function ipver(s) {
	let m = match(s, RE_V4);
	if (m) {
		for (let i = 1; i <= 4; i++)
			if (+m[i] > 255)
				return 0;
		if (m[6] != null && +m[6] > 32)
			return 0;
		return 4;
	}
	if (index(s, ':') >= 0 && match(s, RE_V6)) {
		let p = split(s, '/');
		if (length(p) == 2 && +p[1] > 128)
			return 0;
		// at most one "::" and no more than 8 groups
		if (length(split(p[0], '::')) > 2 || length(split(p[0], ':')) > 8)
			return 0;
		return 6;
	}
	return 0;
};

export function uniq_list(arr) {
	let seen = {}, out = [];
	for (let v in arr) {
		if (seen[v])
			continue;
		seen[v] = true;
		push(out, v);
	}
	return out;
};

// ---------------------------------------------------------------- YAML
// Minimal emitter for the plain data we generate (maps, lists, scalars).
// Strings are always emitted as JSON strings, which are valid YAML scalars.
function yaml_scalar(v) {
	switch (type(v)) {
	case 'string': return sprintf('%J', v);
	case 'bool':   return v ? 'true' : 'false';
	case 'int':
	case 'double': return `${v}`;
	default:       return 'null';
	}
}

function yaml_node(v, indent, out) {
	const pad = substr('                                        ', 0, indent);
	const t = type(v);

	if (t == 'array') {
		for (let item in v) {
			const it = type(item);
			if ((it == 'array' || it == 'object') && length(item)) {
				let sub = [];
				yaml_node(item, indent + 2, sub);
				// fold the first line of the child onto the dash
				push(out, `${pad}- ${ltrim(sub[0])}`);
				for (let i = 1; i < length(sub); i++)
					push(out, sub[i]);
			}
			else if (it == 'array') {
				push(out, `${pad}- []`);
			}
			else if (it == 'object') {
				push(out, `${pad}- {}`);
			}
			else {
				push(out, `${pad}- ${yaml_scalar(item)}`);
			}
		}
	}
	else if (t == 'object') {
		for (let k in keys(v)) {
			const item = v[k];
			const it = type(item);
			if ((it == 'array' || it == 'object') && length(item)) {
				push(out, `${pad}${k}:`);
				yaml_node(item, indent + 2, out);
			}
			else if (it == 'array') {
				push(out, `${pad}${k}: []`);
			}
			else if (it == 'object') {
				push(out, `${pad}${k}: {}`);
			}
			else {
				push(out, `${pad}${k}: ${yaml_scalar(item)}`);
			}
		}
	}
}

export function yaml(v) {
	let out = [];
	yaml_node(v, 0, out);
	return join('\n', out) + '\n';
};
