export interface DiffLineAnchors {
  LEFT: Set<number>;
  RIGHT: Set<number>;
}

export function parseDiffLines(diff: string): Map<string, Set<number>> {
  const anchors = parseDiffLineAnchors(diff);
  return new Map([...anchors.entries()].map(([file, sides]) => [file, sides.RIGHT]));
}

export function parseDiffLineAnchors(diff: string): Map<string, DiffLineAnchors> {
  const anchors = new Map<string, DiffLineAnchors>();
  const lines = diff.split("\n");

  let currentPath: string | null = null;
  let inHunk = false;
  let leftLine = 0;
  let rightLine = 0;

  for (const line of lines) {
    const fileMatch = line.match(/^diff --git a\/.+ b\/(.+)$/);
    if (fileMatch) {
      currentPath = fileMatch[1]!;
      inHunk = false;
      if (!anchors.has(currentPath)) {
        anchors.set(currentPath, { LEFT: new Set(), RIGHT: new Set() });
      }
      continue;
    }

    const hunkMatch = line.match(/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
    if (hunkMatch) {
      leftLine = parseInt(hunkMatch[1]!, 10);
      rightLine = parseInt(hunkMatch[2]!, 10);
      inHunk = true;
      continue;
    }

    if (!currentPath || !inHunk) continue;
    const fileAnchors = anchors.get(currentPath)!;

    if (line.startsWith("+")) {
      fileAnchors.RIGHT.add(rightLine);
      rightLine++;
    } else if (line.startsWith("-")) {
      fileAnchors.LEFT.add(leftLine);
      leftLine++;
    } else if (line.startsWith(" ")) {
      fileAnchors.LEFT.add(leftLine);
      fileAnchors.RIGHT.add(rightLine);
      leftLine++;
      rightLine++;
    }
  }

  return anchors;
}
