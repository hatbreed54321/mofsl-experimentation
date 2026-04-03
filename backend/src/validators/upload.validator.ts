import { z } from 'zod';

export const uploadQuerySchema = z.object({
  mode: z.enum(['replace', 'append']).default('replace'),
});

export const deleteEligibleClientsBodySchema = z.object({
  // Optional: if uploadBatchId is provided, delete only that batch.
  // If omitted, delete ALL eligible clients for the experiment.
  uploadBatchId: z.string().uuid().optional(),
});

export const listQuerySchema = z.object({
  // Cursor-based pagination
  cursor: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(100),
});

export type UploadQuery = z.infer<typeof uploadQuerySchema>;
export type DeleteEligibleClientsBody = z.infer<typeof deleteEligibleClientsBodySchema>;
export type ListQuery = z.infer<typeof listQuerySchema>;
