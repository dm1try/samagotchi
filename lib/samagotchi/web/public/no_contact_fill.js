// A text field that isn't a contact form. iOS Safari offers its "AutoFill
// Contact" bar above the keyboard on a field that looks like one (no
// autocomplete, a name or label with a contact word in it: name, email,
// title, phone…), and once it has seen one it offers it on the page's later
// text fields too, the composer among them. What it respects against that:
// autocomplete="off" and a name with no contact word in it.
//
// Fields drawn by a lit-html template can't call this: they carry the same
// two attributes in the template (autocomplete="off", a chi-… name), and
// spec/web/public/no_contact_fill.test.js checks the templates for them.
//
// A module of its own: static JS is cached at unversioned URLs.

// The words iOS reads as a contact field, in a name, a placeholder or a
// label. A field's name never has one; its wording avoids them.
export const CONTACT_WORDS = /\b(name|e-?mail|title|phone|tel|address|street|city|zip|postal|country|company|organi[sz]ation|first|last|given|family|nickname)\b/i;

// +input+ an input or textarea; +name+ its form name (no contact word in
// it: a chi-… name). +prose+: the reader writes prose here, so autocorrect
// stays on (autocomplete="off" turns it off in some browsers).
export function noContactFill(input, name, { prose = false } = {}) {
  if (CONTACT_WORDS.test(name)) throw new Error(`noContactFill: "${name}" reads as a contact field`);
  input.setAttribute("autocomplete", "off");
  if (prose) input.setAttribute("autocorrect", "on");
  input.name = name;
  return input;
}
