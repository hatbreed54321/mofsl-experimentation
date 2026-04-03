import { z } from 'zod';

export const uploadQuerySchema = z.object({
  mode: z.enum(['replace', 'append']).default('replace'),
});

export const listQuerySchema = z.object({
  // Cursor-based pagination
  cursor: z.string().uuid().optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(100),
});

export type UploadQuery = z.infer<typeof uploadQuerySchema>;
export type ListQuery = z.infer<typeof listQuerySchema>;
