import { z } from "zod";

export const PrdSlicesOutput = z.object({
  slices: z.array(
    z.object({
      title: z.string().min(1),
      type: z.enum(["AFK", "HITL"]).default("AFK"),
      whatToBuild: z.string().min(1),
      acceptanceCriteria: z.array(z.string().min(1)).min(1),
      blockedBy: z.array(z.string()).default([]),
    }),
  ).min(1),
});

export type PrdSlicesOutput = z.infer<typeof PrdSlicesOutput>;
