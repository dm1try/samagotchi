// The e2e suite's renderer: a fixed SVG with the source's first line in a
// <title>; a source holding "throw me" throws. On a chi that takes regions
// (chi.features.regions) it reports one node, on the left of the picture.
chi.defineRenderer({
  render(source) {
    if (source.includes("throw me")) throw new Error("the fixture throws\nmore words");
    const first = source.split("\n")[0].replace(/[<&]/g, "");
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="100%" viewBox="0 0 240 60"><title>${first}</title><rect width="240" height="60" rx="6" fill="#5aa9ff"/></svg>`;
    if (!chi.features?.regions) return svg;
    return { svg, regions: [{ kind: "node", id: "A", label: "First node", box: [0.05, 0.1, 0.4, 0.8] }] };
  },
});
