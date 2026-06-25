import { z } from "zod";
import { InlineCommentSchema } from "../lib/inline-comment.js";

export const ReviewOutput = z.object({
  summary: z.string().min(1),
  inlineComments: z.array(InlineCommentSchema).default([]),
  replies: z
    .array(
      z.object({
        commentId: z.string().min(1),
        body: z.string().min(1),
      }),
    )
    .default([]),
});

export type ReviewOutput = z.infer<typeof ReviewOutput>;
