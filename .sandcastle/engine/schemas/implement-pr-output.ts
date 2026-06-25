import { z } from "zod";
import { InlineCommentSchema } from "../lib/inline-comment.js";

export const ImplementPrOutput = z.object({
  threadReplies: z
    .array(
      z.object({
        commentId: z.string().min(1),
        body: z.string().min(1),
      }),
    )
    .default([]),
  newInlineComments: z.array(InlineCommentSchema).default([]),
  topLevelComments: z
    .array(
      z.object({
        body: z.string().min(1),
      }),
    )
    .default([]),
});

export type ImplementPrOutput = z.infer<typeof ImplementPrOutput>;
