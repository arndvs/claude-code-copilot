import { z } from "zod";

export const UpdateBranchOutput = z.object({
  comment: z.string().min(1),
});

export type UpdateBranchOutput = z.infer<typeof UpdateBranchOutput>;
