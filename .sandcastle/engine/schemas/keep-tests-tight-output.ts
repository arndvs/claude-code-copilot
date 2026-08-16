import { z } from "zod";

const ChangedSchema = z.object({
  status: z.literal("changed"),
  summary: z.string().min(1),
  removed: z.array(z.string().min(1)),
  consolidated: z.array(z.string().min(1)),
  kept: z.array(z.string().min(1)),
  diffStat: z.string().min(1),
});

const NoChangesSchema = z.object({
  status: z.literal("no-changes"),
  reason: z.string().min(1),
});

export const KeepTestsTightOutput = z.discriminatedUnion("status", [
  ChangedSchema,
  NoChangesSchema,
]);

export type KeepTestsTightOutput = z.infer<typeof KeepTestsTightOutput>;
