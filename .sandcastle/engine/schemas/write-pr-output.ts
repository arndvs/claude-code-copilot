import { z } from "zod";

export const WritePrOutput = z.object({
  prTitle: z.string().min(1).max(256),
  prDescription: z.string().min(1),
});

export type WritePrOutput = z.infer<typeof WritePrOutput>;
