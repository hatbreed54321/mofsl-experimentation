import { S3Client, PutObjectCommand, GetObjectCommand } from '@aws-sdk/client-s3';
import { config } from '../config';

function createS3Client(): S3Client {
  const clientConfig: ConstructorParameters<typeof S3Client>[0] = {
    region: config.s3Region,
  };

  if (config.s3Endpoint) {
    // LocalStack (local dev) — force path-style addressing and static credentials
    clientConfig.endpoint = config.s3Endpoint;
    clientConfig.forcePathStyle = true;
    clientConfig.credentials = {
      accessKeyId: process.env['AWS_ACCESS_KEY_ID'] ?? 'test',
      secretAccessKey: process.env['AWS_SECRET_ACCESS_KEY'] ?? 'test',
    };
  }

  return new S3Client(clientConfig);
}

const s3Client = createS3Client();

export async function uploadToS3(key: string, body: Buffer, contentType: string): Promise<void> {
  await s3Client.send(
    new PutObjectCommand({
      Bucket: config.s3Bucket,
      Key: key,
      Body: body,
      ContentType: contentType,
      ServerSideEncryption: config.s3Endpoint ? undefined : 'AES256',
    }),
  );
}

export async function downloadFromS3(key: string): Promise<Buffer> {
  const response = await s3Client.send(
    new GetObjectCommand({
      Bucket: config.s3Bucket,
      Key: key,
    }),
  );

  if (!response.Body) {
    throw new Error(`S3 object '${key}' has no body`);
  }

  const chunks: Uint8Array[] = [];
  for await (const chunk of response.Body as AsyncIterable<Uint8Array>) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}
