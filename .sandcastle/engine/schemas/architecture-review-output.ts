import { z } from "zod";

const ProposedSchema = z.object({
  status: z.literal("proposed"),
  title: z.string().min(1).max(256),
  body: z.string().min(1),
  oneLineSummary: z.string().min(1),
  candidatesConsidered: z.array(z.string().min(1)).min(1),
});

const SkippedSchema = z.object({
  status: z.literal("skipped"),
  reason: z.string().min(1),
});

export const ArchitectureReviewOutput = z.discriminatedUnion("status", [
  ProposedSchema,
  SkippedSchema,
]);

export type ArchitectureReviewOutput = z.infer<typeof ArchitectureReviewOutput>;
