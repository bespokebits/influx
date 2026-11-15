// Writes manifest.json for this review from the pictures in images/.
//
//   node build-manifest.mjs
//
// Surface ids and column keys are what votes and notes are kept by: keep
// them the same when the review is pushed again.
import { existsSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const captured = '2026-11-13';
const commit = '521082c';
const where = {
  ios: 'on the iPhone 18 Pro simulator (iOS 27)',
  mac: 'in the test process on macOS 27',
};

const intro = `Two things the reader can't see today. A thread can come back with posts missing from it, and the thread view shows it as if it were whole. A post can quote a post that is gone or that the source can't show, and the row shows nothing where the quote would be, so its text can read oddly. Both came up with rich posts (ADR 0031), but neither is specific to one service: any service that reports a missing post or an unavailable quote would use the same treatment.

Decided: both must exist. A thread with a gap says so, for each reason the service gives (deleted by its author; private, blocked or unreachable; not collected), among the earlier posts and among the later ones. A quote of an unavailable post says the quoted post is unavailable and offers its address. In the timeline, the unavailable quote's box has a fixed height, set by the text size alone, so a row's height is still final before it is shown and the row is still drawn into one bitmap.

Open: which treatment, for each surface. A, B and C go from lightest to heaviest and use the same idea on both surfaces: A is a quiet line of text, B a hairline frame, C a washed note. They can be mixed (say, B for quotes and C for gaps), and wording can go in the notes.

A gap doesn't say where in its list it falls, or how many posts it stands for, so every option puts it at the edge of its list: above the first earlier post, below the last later one, and the words say "some posts", never a count.

The thread view shows no quote card at all today, for any quote. Every option for the thread adds the timeline's quote card there, in the thread's own type sizes, so the unavailable quote has something to match.

How the pictures were made, ${captured}, from the app at ${commit}, with made-up posts on example.com addresses: "Current" is the app's own code. Timeline rows are the bitmaps the timeline's cells show, drawn by the app's row renderer and stacked; the toolbar and sidebar are not in them. The thread is the app's own thread view, fed the made-up thread through the stand-in connector sample runs use. The options are mock-ups made by the same capture fixture: a row is the app's own bitmap with room made for the new box, drawn in the row's fonts and colours; a thread is a copy of the thread view's layout with the new parts added. On the iPhone the thread is in a page sheet, as the timeline opens it; on the Mac the sheet's title bar and Done button belong to the window and are not drawn. The fixture thread is a rich-feed thread, whose posts have no like or boost buttons; the timeline rows are Mastodon-style posts, which do.`;

const columns = [
  {
    key: 'current',
    label: 'Current',
    kind: 'shipped',
    blurb: `What ships at ${commit}, captured ${captured} from the app's own code: the timeline's row renderer and the thread view, with made-up posts. On the iPhone it was drawn ${where.ios}; on the Mac it was drawn ${where.mac} (cacheDisplay), without the sheet's title bar. A gap is never drawn, and an unavailable quote leaves nothing.`,
  },
  {
    key: 'A',
    label: 'A · A quiet line',
    kind: 'proposal',
    blurb: `Mock-up, made ${captured} by the capture fixture over the app at ${commit}. The lightest: a single line of secondary-ink text, no box. A gap is an italic sentence with an ellipsis, between the thread's rules. An unavailable quote is one line under the text, "Quoted post unavailable · example.com", the site underlined and tappable.`,
  },
  {
    key: 'B',
    label: 'B · A hairline frame',
    kind: 'proposal',
    blurb: `Mock-up, made ${captured} by the capture fixture over the app at ${commit}. The shape of what is missing: a gap is a dashed hairline frame where a post would be, one per reason, with a symbol, a short title and a line of detail. An unavailable quote keeps the quote card's hairline box, holding "The quoted post is unavailable." in italic and the site.`,
  },
  {
    key: 'C',
    label: 'C · A washed note',
    kind: 'proposal',
    blurb: `Mock-up, made ${captured} by the capture fixture over the app at ${commit}. The most visible: a note on the wash colour the link cards use. A gap's note has a small heading, a sentence per reason and a link to the whole thread on its own site. An unavailable quote is a washed slip with a symbol, "Quoted post unavailable" and the address itself.`,
  },
];

const gapCases = [
  ['deleted', 'Deleted, earlier and later'],
  ['unavailable', 'Unavailable, earlier and later'],
  ['not-collected', 'Not collected, earlier and later'],
  ['two-reasons', 'Two reasons among the earlier posts'],
];

function image(file, column, variant, caption) {
  if (!existsSync(join(here, file))) throw new Error(`missing ${file}`);
  return caption ? { column, file, variant, caption } : { column, file, variant };
}

function gapImages(platform) {
  const images = [];
  for (const look of ['light', 'dark']) {
    // Nothing of a gap is drawn today, so every case looks the same.
    images.push(image(`images/${platform}-gaps-current-deleted-${look}.webp`, 'current', look,
      'The same for every reason: no gap is drawn'));
  }
  for (const column of ['A', 'B', 'C']) {
    for (const look of ['light', 'dark']) {
      for (const [name, caption] of gapCases) {
        images.push(image(`images/${platform}-gaps-${column}-${name}-${look}.webp`, column, look, caption));
      }
    }
  }
  return images;
}

function simpleImages(platform, surface) {
  const images = [];
  for (const column of ['current', 'A', 'B', 'C']) {
    for (const look of ['light', 'dark']) {
      images.push(image(`images/${platform}-${surface}-${column}-${look}.webp`, column, look,
        column === 'current' ? undefined : 'Mock-up'));
    }
  }
  return images;
}

const gapWhy = (device) => `The thread view (Open Thread) shows the posts a post answers above it and the author's continuations below. When the service says some of them are missing, nothing shows it, so the thread reads as complete. Each picture is one thread ${device}: two earlier posts, the opened post on its wash, and two continuations, with the service reporting gaps as named in each caption.`;
const gapCaptions = {
  current: 'The thread as if whole. The service said posts were missing, and nothing says so.',
  A: 'One italic line per reason, at the top of the earlier posts and the foot of the later ones. Lightest, and easy to miss.',
  B: 'A dashed frame per reason, sitting where a post would: symbol, "Earlier posts deleted", "Removed by their authors." It can read as exactly one post in that spot, which the service doesn\'t say.',
  C: 'A washed note at the edge of the list: "EARLIER POSTS MISSING", a sentence per reason, and "Read the whole thread on example.com", which opens the post\'s own page.',
};

const rowWhy = (device) => `Two timeline rows ${device}: a post quoting a post that is still there (the quote card), and below it a post quoting one that is gone. The app stores the second without a quote, so the row shows nothing, and its "the one I quoted" points at nothing. The box must have a fixed height, since a row's height is final before it is shown.`;
const rowCaptions = {
  current: 'The top row has its quote card. The bottom row quotes a post that is gone and shows nothing.',
  A: 'One line of secondary ink where the card would be. Height: one meta line.',
  B: 'The quote card\'s hairline box, with an italic line and the site. Height: padding, one line of the quote text\'s size, one meta line.',
  C: 'A washed slip, like a small link card: symbol, "Quoted post unavailable" and the address, cut in the middle if long. Height: padding and two meta lines.',
};

const threadQuoteWhy = (device) => `The same posts in the thread view ${device}. The thread view draws no quote card at all today, so neither quote shows, the one that is there or the one that is gone. Every option adds the quote card to the thread (on the earlier post) as well as the unavailable treatment (on the opened post).`;
const threadQuoteCaptions = {
  current: 'No quote card on either post: the thread view doesn\'t draw quotes.',
  A: 'The quote card on the earlier post; one quiet line on the opened post.',
  B: 'The quote card on the earlier post; the same hairline box, saying the post is unavailable, on the opened post.',
  C: 'The quote card on the earlier post; a washed slip with the address on the opened post.',
};

const surfaces = [];
for (const [platform, group, device] of [['ios', 'iPhone', 'on the iPhone'], ['mac', 'Mac', 'on the Mac']]) {
  surfaces.push({
    id: `${platform}-thread-gaps`, group, title: 'Thread: missing posts', why: gapWhy(device), captions: gapCaptions,
    images: gapImages(platform),
  });
  surfaces.push({
    id: `${platform}-row-unavailable-quote`, group, title: 'Timeline: unavailable quote', why: rowWhy(device), captions: rowCaptions,
    images: simpleImages(platform, 'row'),
  });
  surfaces.push({
    id: `${platform}-thread-unavailable-quote`, group, title: 'Thread: unavailable quote', why: threadQuoteWhy(device),
    captions: threadQuoteCaptions, images: simpleImages(platform, 'thread-quote'),
  });
}

const manifest = {
  slug: 'influx-thread-gaps-unavailable-quotes',
  title: 'Influx · Missing posts in threads and unavailable quotes',
  intro,
  columns,
  surfaces,
};
writeFileSync(join(here, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`manifest.json: ${surfaces.length} surfaces, ${surfaces.reduce((n, s) => n + s.images.length, 0)} images`);
