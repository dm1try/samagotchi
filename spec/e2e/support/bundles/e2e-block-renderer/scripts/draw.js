// The e2e suite's renderer: a fixed SVG with the source's first line in a
// <title>; a source holding "throw me" throws.
chi.defineRenderer({
  render(source) {
    if (source.includes("throw me")) throw new Error("the fixture throws\nmore words");
    const first = source.split("\n")[0].replace(/[<&]/g, "");
    return `<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 240 60"><title>${first}</title><rect width="240" height="60" rx="6" fill="#5aa9ff"/></svg>`;
  },
});
